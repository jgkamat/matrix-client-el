;; Here is a playground for implementing the latest version of the
;; API, r0.2.0.  Confusingly, "v1" of the API is older and more
;; primitive than "r0".  Apparently the API was not considered
;; "released" then, and now it is, so the versions are named with an R
;; instead of a V.

;; TODO: Consider let-binding `json-array-type' to `list'.  I'm not
;; sure there's any advantage to using vectors, and it makes the code
;; more error-prone because some things are lists and some vectors.

;;; Code:

;;;; Requirements

(require 'cl-lib)
(require 'eieio)
(require 'map)
(require 'seq)

(require 'a)
(require 'dash)
(require 'json)
(require 'request)
(require 's)

(require 'matrix-macros)

;;;; Variables

(defvar matrix-log-buffer "*matrix-log*"
  "Name of buffer used by `matrix-log'.")

(defvar matrix-synchronous nil
  "When non-nil, run `matrix-request' requests synchronously.")

;;;; Macros

(defmacro matrix-defclass (name superclasses slots &rest options-and-doc)
  (declare (indent defun))
  (let* ((slot-inits (-non-nil (--map (let ((name (car it))
                                            (initer (plist-get (cdr it) :instance-initform)))
                                        (when initer
                                          (list 'setq name initer)))
                                      slots)))
         (slot-names (mapcar #'car slots))
         (around-fn-name (intern (concat (symbol-name name) "-initialize")))
         (docstring (format "Inititalize instance of %s." name)))
    `(progn
       (defclass ,name ,superclasses ,slots ,@options-and-doc)
       (when (> (length ',slot-inits) 0)
         (cl-defmethod initialize-instance :after ((this ,name) &rest _)
                       ,docstring
                       (with-slots ,slot-names this
                         ,@slot-inits))))))

(cl-defmacro matrix-defcallback (name type docstring &key slots body)
  "Define callback function NAME on TYPE with DOCSTRING and BODY.
This defines a method on a TYPE object, compatible with the
`request' callback API.  The object of TYPE will be available as
TYPE without any `matrix-' prefix.  The method's name will be
`matrix-NAME-callback'. Object SLOTS are made available
automatically with `with-slots'.  Keyword arguments DATA,
ERROR-THROWN, SYMBOL-STATUS, and RESPONSE are defined
automatically, and other keys are allowed."
  (declare (indent defun))
  (let ((name (intern (concat "matrix-" (symbol-name name) "-callback")))
        (instance (intern (nth 1 (s-match (rx "matrix-" (group (1+ anything)))
                                          (symbol-name type))))))
    `(cl-defmethod ,name ((,instance ,type) &key data error-thrown symbol-status response
                          &allow-other-keys)
       (with-slots ,slots ,instance
         ,body))))

;;;; Classes

(matrix-defclass matrix-session ()
  ((user :initarg :user
         :initform nil
         :type string
         :documentation "The fully qualified user ID, e.g. @user:matrix.org.")
   (server :initarg :server
           :initform nil
           :instance-initform (nth 2 (s-match (rx "@" (group (1+ (not (any ":")))) ":" (group (1+ anything)))
                                              user))
           :type string
           :documentation "FQDN of server, e.g. \"matrix.org\" for the official homeserver.
Derived automatically from USER.")
   (api-url-prefix :type string
                   :instance-initform (concat "https://" server "/_matrix/client/r0/")
                   :documentation "URL prefix for API requests.
Derived automatically from server-name and built-in API version.")
   (device-id :initarg :device-id
              ;; FIXME: Does the initform work for this?  When this
              ;; file gets byte-compiled, does it get hard-coded in
              ;; the class definition?  Does this need to be in an
              ;; instance-initform instead?
              :initform (md5 (concat "matrix-client.el" (system-name)))
              :documentation "ID of the client device.")
   (initial-device-display-name
    :initarg :initial-device-display-name
    ;; FIXME: Does the initform work for this?  When this
    ;; file gets byte-compiled, does it get hard-coded in
    ;; the class definition?  Does this need to be in an
    ;; instance-initform instead?
    :initform (concat "matrix-client.el @ " (system-name))
    :type string
    :documentation "A display name to assign to the newly-created device.
Ignored if device_id corresponds to a known device.")
   (access-token :initarg :access-token
                 :initform nil
                 :documentation "API access_token.")
   (txn-id :initarg :txn-id
           :initform 0
           :type integer
           :documentation "Transaction ID.
Defaults to 0 and should be automatically incremented for each request.")
   (rooms :initform nil
          :initarg :rooms
          :type list
          :documentation "List of room objects user has joined.")
   (next-batch :initform nil
               :type string
               :documentation "The batch token to supply in the since param of the next /sync request."))
  :allow-nil-initform t)

(matrix-defclass matrix-room ()
  ((session :initarg :session
            :type matrix-session)
   (id :documentation "Fully-qualified room ID."
       :initarg :id
       :type string
       :initform nil)
   (members :documentation "List of room members, as user objects."
            :type list
            :initform nil)
   (state :documentation "Updates to the state, between the time indicated by the since parameter, and the start of the timeline (or all state up to the start of the timeline, if since is not given, or full_state is true)."
          :initform nil)
   (timeline :documentation "List of timeline events."
             :type list
             :initform nil)
   (prev-batch :documentation "A token that can be supplied to to the from parameter of the rooms/{roomId}/messages endpoint."
               ;; :type string
               :initform nil)
   (ephemeral :documentation "The ephemeral events in the room that aren't recorded in the timeline or state of the room. e.g. typing."
              :initform nil)
   (account-data :documentation "The private data that this user has attached to this room."
                 :initform nil)
   (unread-notifications :documentation "Counts of unread notifications for this room."
                         :initform nil))
  :allow-nil-initform t)

;;;; Functions

(cl-defun matrix-log (message &rest args)
  "Log MESSAGE with ARGS to Matrix log buffer and return non-nil.
MESSAGE and ARGS should be a string and list of strings for
`format'."
  (with-current-buffer (get-buffer-create matrix-log-buffer)
    (insert (apply #'format message args) "\n")
    ;; Returning t is more convenient than nil, which is returned by `message'.
    t))

(defun matrix-get (&rest args)
  "Call `matrix-request' with ARGS for a \"GET\" request."
  (apply #'matrix-request args ))

(defun matrix-post (&rest args)
  "Call `matrix-request' with ARGS for a \"POST\" request."
  (nconc args (list :method 'post))
  (apply #'matrix-request args))

(defun matrix-put (&rest args)
  "Call `matrix-request' with ARGS for a \"PUT\" request."
  (nconc args (list :method 'put))
  (apply #'matrix-request args))

;;;; Methods

;;;;; Request

;; NOTE: Every callback defined that is passed to `matrix-request'
;; should be a method specialized on `matrix-session'.  While it means
;; that sometimes we must look up a room object by room ID, since we
;; can't specialize on `matrix-room', it also means that we only need
;; to pass the method name as the callback, rather than a partially
;; applied method.  This might be a worthwhile tradeoff, but we might
;; change this later.

(cl-defmethod matrix-request ((session matrix-session) endpoint data callback
                              &optional &key (method 'get) (error-callback #'matrix-request-error-callback))
  "Make request to ENDPOINT on SESSION with DATA and call CALLBACK on success.
Request is made asynchronously.  METHOD should be a symbol,
`get' (the default) or `post'.  ENDPOINT may be a string or
symbol and should represent the final part of the API
URL (e.g. for \"/_matrix/client/r0/login\", it should be
\"login\".  DATA should be an alist which will be automatically
encoded to JSON.  CALLBACK should be a method specialized on
`matrix-session', whose subsequent arguments are defined in
accordance with the `request' package's API.  ERROR-CALLBACK, if
set, will be called if the request fails."
  (with-slots (api-url-prefix access-token) session
    (let* ((url (url-encode-url
                 (concat api-url-prefix (cl-typecase endpoint
                                          (string endpoint)
                                          (symbol (symbol-name endpoint))))))
           (data (map-filter
                  ;; Remove keys with null values
                  (lambda (k v)
                    v)
                  data))
           (callback (cl-typecase callback
                       ;; If callback is a symbol, apply session to
                       ;; it.  If it's an already-partially-applied
                       ;; function, use it as-is.
                       ;; FIXME: Add to docstring.
                       (symbolp (apply-partially callback session))
                       (t callback)))
           (method (upcase (symbol-name method)))
           (request-log-level 'debug))
      (matrix-log "REQUEST: %s" (a-list 'url url
                                        'method method
                                        'data data
                                        'callback callback))
      (pcase method
        ("GET" (request url
                        :type method
                        :headers (a-list 'Authorization (format "Bearer %s" access-token))
                        :params data
                        :parser #'json-read
                        :success callback
                        :error (apply-partially error-callback session)
                        :sync matrix-synchronous))
        ("POST" (request url
                         :type method
                         :headers (a-list 'Content-Type "application/json"
                                          'Authorization (format "Bearer %s" access-token))
                         :data (json-encode data)
                         :parser #'json-read
                         :success callback
                         :error (apply-partially error-callback session)
                         :sync matrix-synchronous))
        ("PUT" (request url
                        :type method
                        :headers (a-list 'Content-Type "application/json"
                                         'Authorization (format "Bearer %s" access-token))
                        :data (json-encode data)
                        :parser #'json-read
                        :success callback
                        :error (apply-partially error-callback session)
                        :sync matrix-synchronous))))))

(matrix-defcallback request-error matrix-session
  "Callback function for request error."
  :slots (user)
  :body (let ((msg (format "REQUEST ERROR: %s: %s" user data)))
          (warn msg)
          (matrix-log msg)))

;;;;; Login

(cl-defmethod matrix-login ((session matrix-session) password)
  "Log in to SESSION with PASSWORD.
Session should already have its USER slot set, and optionally its
DEVICE-ID and INITIAL-DEVICE-DISPLAY-NAME."
  (with-slots (user device-id initial-device-display-name) session
    (matrix-post session 'login (a-list 'type "m.login.password"
                                        'user user
                                        'password password
                                        'device_id device-id
                                        'initial_device_display_name initial-device-display-name)
                 #'matrix-login-callback)))

(matrix-defcallback login matrix-session
  "Callback function for successful login.
Set access_token and device_id in session."
  :slots (access-token device-id)
  :body (pcase-let* (((map access_token device_id) data))
          (setq access-token access_token
                device-id device_id)))

;;;;; Sync

(cl-defmethod matrix-sync ((session matrix-session) &key full-state set-presence timeout)
  ;; https://matrix.org/docs/spec/client_server/r0.2.0.html#id126
  (with-slots (access-token next-batch) session
    (matrix-get session 'sync
                (a-list 'since next-batch
                        'full_state full-state
                        'set_presence set-presence
                        'timeout timeout)
                #'matrix-sync-callback)))

(matrix-defcallback sync matrix-session
  "Callback function for successful sync request."
  ;; https://matrix.org/docs/spec/client_server/r0.3.0.html#id167
  :slots (rooms next-batch)
  :body (cl-loop for it in '(rooms presence account_data to_device device_lists)
                 for method = (intern (concat "matrix-sync-" (symbol-name it)))
                 always (if (functionp method)
                            (unless (funcall method session (a-get data it))
                              (setq failure t))
                          (warn "Unimplemented method: %s" method))))

(cl-defmethod matrix-sync-rooms ((session matrix-session) rooms)
  "Process ROOMS from sync response on SESSION."
  ;; https://matrix.org/docs/spec/client_server/r0.3.0.html#id167
  (cl-loop for room in rooms
           always (pcase room
                    (`(join . ,_) (matrix-sync-join session room))
                    (`(invite .  ,_) (matrix-log "Would process room invites: %s" room))
                    (`(leave . ,_) (matrix-log "Would process room leaves: %s" room)))))

(cl-defmethod matrix-sync-join ((session matrix-session) join)
  "Sync JOIN, a list of joined rooms, on SESSION."
  ;; https://matrix.org/docs/spec/client_server/r0.3.0.html#id167
  (with-slots (rooms) session
    (cl-loop for it in (cdr join)
             always (pcase-let* ((`(,joined-room-id . ,joined-room) it)
                                 ;; Room IDs are decoded from JSON as symbols, so we convert to strings.
                                 (room-id (symbol-name joined-room-id))
                                 (params '(state timeline ephemeral account_data unread_notifications))
                                 (room (or (--first (equal (oref it id) room-id)
                                                    rooms)
                                           ;; Make new room
                                           (let ((new-room (matrix-room :session session
                                                                        :id room-id)))
                                             (push new-room rooms)
                                             new-room))))
                      (cl-loop for param in params
                               for method = (intern (concat "matrix-sync-" (symbol-name param)))
                               always (if (functionp method)
                                          (funcall method room (a-get joined-room param))
                                        ;; `warn' seems to return non-nil.  Convenient.
                                        (warn "Unimplemented method: %s" method-name)))))))

(cl-defmethod matrix-sync-state ((room matrix-room) state)
  "Sync STATE in ROOM."
  (pcase-let (((map events) state))
    ;; events is an array, not a list, so we can't use --each.
    (seq-doseq (event events)
      (matrix-log "Would process state event in %s: " room event))
    t))

(cl-defmethod matrix-sync-timeline ((room matrix-room) timeline-sync)
  "Sync TIMELINE-SYNC in ROOM."
  (with-slots (timeline prev-batch) room
    (pcase-let (((map events limited prev_batch) timeline-sync))
      (seq-doseq (event events)
        (push event timeline))
      (setq prev-batch prev_batch))))

(cl-defmethod matrix-messages ((session matrix-session) room-id
                               &key (direction "b") limit)
  "Request messages for ROOM-ID in SESSION.
DIRECTION must be \"b\" (the default) or \"f\".  LIMIT is the
maximum number of events to return (default 10)."
  (pcase-let* (((eieio rooms) session)
               (room (object-assoc room-id :id rooms))
               ((eieio prev-batch) room))
    (matrix-get session (format "rooms/%s/messages" room-id)
                (a-list 'from prev-batch
                        'dir direction
                        'limit limit)
                (apply-partially #'matrix-messages-callback room))))

(matrix-defcallback messages matrix-room
  "Callback for /rooms/{roomID}/messages."
  :slots (timeline prev-batch)
  :body (pcase-let* (((map start end chunk) data))
          ;; NOTE: API docs:
          ;; start: The token the pagination starts from. If dir=b
          ;; this will be the token supplied in from.
          ;; end: The token the pagination ends at. If dir=b this
          ;; token should be used again to request even earlier
          ;; events.

          ;; FIXME: Does prev-batch need to be stored in timeline
          ;; rather than the room?  is there a prev-batch for other
          ;; things besides timeline?
          (seq-doseq (event chunk)
            (push event timeline))
          (setq prev-batch end)))

(cl-defmethod matrix-sync-ephemeral ((room matrix-room) ephemeral)
  "Sync EPHEMERAL in ROOM."
  (pcase-let (((map events) ephemeral))
    (seq-doseq (event events)
      (matrix-log "Would process ephemeral event in %s: " room event))
    t))

(cl-defmethod matrix-sync-account_data ((room matrix-room) account-data)
  "Sync ACCOUNT-DATA in ROOM."
  (pcase-let (((map events) account-data))
    (seq-doseq (event events)
      (matrix-log "Would process account-data event in %s: " room event))
    t))

(cl-defmethod matrix-sync-unread_notifications ((room matrix-room) unread-notifications)
  "Sync UNREAD-NOTIFICATIONS in ROOM."
  (pcase-let (((map highlight_count notification_count) unread-notifications))
    (matrix-log "Would process highlight_count in %s: " room highlight_count)
    (matrix-log "Would process notification_count in %s: " room notification_count)
    t))

;;;;; Rooms

(cl-defmethod matrix-create-room ((session matrix-session) &key (is-direct t))
  "Create new room on SESSION.
When IS-DIRECT is non-nil, set that flag on the new room."
  ;; https://matrix.org/docs/spec/client_server/r0.3.0.html#id190
  (matrix-post session 'createRoom (a-list 'is-direct is-direct
                                           'name "test room"
                                           'topic "test topic"
                                           'preset "private_chat"
                                           )
               #'matrix-create-room-callback))

(matrix-defcallback create-room matrix-session
  "Callback for create-room.
Add new room to SESSION."
  :slots (rooms)
  :body (pcase-let* (((map room_id) data)
                     (room (matrix-room :session session
                                        :id room_id)))
          (push room rooms)))

(cl-defmethod matrix-send-message ((room matrix-room) message)
  "Send MESSAGE to ROOM."
  ;; https://matrix.org/docs/spec/client_server/r0.3.0.html#id182
  (with-slots (id session) room
    (with-slots (txn-id) session
      ;; This makes it easy to increment the txn-id
      (let* ((type "m.room.message")
             (content (a-list 'msgtype "m.text"
                              'body message))
             (txn-id (cl-incf txn-id))
             (endpoint (format "rooms/%s/send/%s/%s"
                               id type txn-id)))
        (matrix-put session endpoint
                    content
                    (apply-partially #'matrix-send-message-callback room))))))

(matrix-defcallback send-message matrix-room
  "Callback for send-message."
  ;; For now, just log it, because we'll get it back when we sync anyway.
  :slots nil
  :body (matrix-log "Message \"%s\" sent to room %s. Event ID: %s"
                    (oref room id) message (a-get data 'event_id)))

(cl-defmethod matrix-leave ((room matrix-room))
  "Leave room."
  ;; https://matrix.org/docs/spec/client_server/r0.3.0.html#id203
  (with-slots (id session) room
    (let* ((endpoint (format "rooms/%s/leave" id)))
      (matrix-post session endpoint nil
                   (apply-partially #'matrix-leave-callback room)))))

(matrix-defcallback leave matrix-room
  "Leave room callback."
  :slots (session)
  :body (object-remove-from-list session :rooms room))

(cl-defmethod matrix-forget ((room matrix-room))
  "Forget ROOM."
  ;; https://matrix.org/docs/spec/client_server/r0.3.0.html#id204
  (with-slots (id session) room
    (let* ((endpoint (format "rooms/%s/forget" id)))
      (matrix-post session endpoint nil
                   (apply-partially #'matrix-forget-callback room)))))

(matrix-defcallback forget matrix-room
  "Forget room callback."
  :body (matrix-log "FORGOT ROOM: %s" (oref room id)))

;;; Footer

(provide 'matrix-api-r0.3.0)
