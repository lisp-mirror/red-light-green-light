;;; -*- Mode: LISP; Syntax: COMMON-LISP; Package: RLGL-SERVER; Base: 10 -*-
;;;
;;; Copyright (C) 2018, 2019  Anthony Green <green@moxielogic.com>
;;;                         
;;; rlgl-server is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3, or (at your
;;; option) any later version.
;;;
;;; rlgl-server is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with rlgl-server; see the file COPYING3.  If not see
;;; <http://www.gnu.org/licenses/>.

;; Top level for rlgl-server

(in-package :rlgl-server)

;; ----------------------------------------------------------------------------
;; Default configuration.  Overridden by external config file.
(defvar *config* nil)
(defparameter *default-config-text*
"storage-driver = \"local\"
server-uri = \"http://localhost:8080\"
policy-dir = \"/tmp/policy5/\"
db = \"sqlite\"
sqlite-db-filename = \"/tmp/rlgl5.db\"
")

(defvar *server-uri* nil)

;; ----------------------------------------------------------------------------
(defparameter *rlgl-registry* nil)
(defparameter *http-requests-counter* nil)
(defparameter *http-request-duration* nil)

(defun initialize-metrics ()
  (unless *rlgl-registry*
    (setf *rlgl-registry* (prom:make-registry))
    (let ((prom:*default-registry* *rlgl-registry*))
      (setf *http-requests-counter*
            (prom:make-counter :name "http_requests_total"
                               :help "Counts http request by type"
                               :labels '("method" "app")))
      (setf *http-request-duration*
	    (prom:make-histogram :name "http_request_duration_milliseconds"
                                 :help "HTTP requests duration[ms]"
                                 :labels '("method" "app")
                                 :buckets '(10 25 50 75 100 250 500 750 1000 1500 2000 3000)))
      #+sbcl
      (prom.sbcl:make-memory-collector)
      #+sbcl
      (prom.sbcl:make-threads-collector)
      (prom.process:make-process-collector))))

;; ----------------------------------------------------------------------------
;; Storage backends

(defclass storage-backend ()
  ((key :initarg :key :reader key)))

(defvar *storage-driver*
  (make-instance 'local-storage-backend))
(init *storage-driver*)

;; ----------------------------------------------------------------------------
;; Parsing backends

(defclass report-parser ()
  ((name :initarg :name :reader name)
   (title :initarg :title :reader title)))

;; Run all of the scripts in recog.d until we find
;; a match.
(defun recognize-report (doc)
  "Try to recognize the report type in the string DOC.  If we
recognize it, return a RLGL-SERVER:PARSER object, NIL otherwise."
  (let ((fname
	 (cl-fad:with-output-to-temporary-file (stream)
	   (print doc stream))))
    (let ((scripts (cl-fad:list-directory "recog.d"))
	  (result nil))
      (find-if (lambda (script)
		 (let ((output (inferior-shell:run/ss
				(str:concat
				 (namestring script) " "
				 (namestring fname)))))
		   (setf result output)
		   (> (length output) 0)))
	       scripts)
      (delete-file fname)
      (when (> (length result) 0)
	(make-instance (read-from-string
			(str:concat "rlgl-server:parser/" result)))))))

;; ----------------------------------------------------------------------------
;; API routes

(snooze:defroute start (:get :text/plain)
  ;; Return a random 7 character hash
  (rlgl.util:random-hex-string 7))

(snooze:defroute login (:get :text/plain)
  "rlgl-server v0.1 connected")

(snooze:defroute report-log (:get :text/plain &key id)
  (rlgl.db:report-log id))

(snooze:defroute evaluate (:post :application/json)
  (let ((json
	 (json:decode-json-from-string
	  (funcall
	   (read-from-string "hunchentoot:raw-post-data") :force-text t))))
    (let ((policy-name (cdr (assoc :POLICY json)))
	  (player (cdr (assoc :ID json))))
      (if (rlgl.util:valid-url? policy-name)
	  (setf *policy* (make-policy policy-name))
	  (print "NO POLICY"))
      (unless player
	"ERROR: missing ID")
      (let* ((doc (read-document *storage-driver* (cdr (assoc :REF json))))
	     (filename (cdr (assoc :NAME json)))
	     (parser (or (recognize-report doc)
			 (when (str:ends-with? ".csv" filename)
			   (make-instance 'parser/csv))))
	     (tests (parse-report parser doc)))
	(if (null tests)
	    "ERROR"
	    (progn
	      (multiple-value-bind (red-or-green processed-results)
		  (apply-policy *policy* tests)
		(let ((stream (make-string-output-stream)))
		  (render stream (cdr (assoc :REF json)) processed-results
			  (title parser)
			  (commit-url-format *policy*))
		  (let ((ref (store-document *storage-driver*
					     (flexi-streams:string-to-octets
					      (get-output-stream-string stream)))))
		    (rlgl.db:record-log player (version *policy*) red-or-green ref)
		    (format nil "~A: ~A/doc?id=~A~%"
			    red-or-green
			    *server-uri*
			    ref))))))))))

(snooze:defroute upload (:post :application/octet-stream)
  (store-document *storage-driver* (hunchentoot:raw-post-data)))

(snooze:defroute doc (:get :text/html &key id)
  (read-document *storage-driver* id))

;;; END ROUTE DEFINITIONS -----------------------------------------------------

;;; Render processed results to HTML

(defparameter *unknown-matcher*
  (make-policy-matcher :kind :unknown))

(defun render (stream report-ref results title commit-url-format)
  ;; We need to sort the results in order FAIL, XFAIL, and PASS, but
  ;; preserve order otherwise.
  (let ((fail nil)
	(xfail nil)
	(pass nil)
	(unknown nil))
    (dolist (item results)
      (if (car item)
	  (let ((kind (kind (car item))))
	    (cond
	      ((eq kind :FAIL)
	       (setf fail (cons item fail)))
	      ((eq kind :XFAIL)
	       (setf xfail (cons item xfail)))
	      ((eq kind :PASS)
	       (setf pass (cons item pass)))
	      ((t t)))) ; FIXME: abort
	  (setf unknown (cons (cons *unknown-matcher*
				    (cdr item))
			      unknown))))
    (setf results
	  (concatenate 'list
		       (reverse fail)
		       (reverse xfail)
		       (reverse pass)
		       (reverse unknown))))
  (let ((*html* stream))
    (with-html
	(:doctype)
      (:html
       (:head
	(:meta :charset "utf-8")
	(:meta :name "viewport" :content "width=device-width, initial-scale=1, shrink-to-fit=no")
	(:link :rel "icon" :href "images/rlgl.svg.png")
	(:title "Report")
	(:link :rel "stylesheet" :href "css/rlgl.css")
	(:link :attrs (list :rel "stylesheet"
			    :href "https://stackpath.bootstrapcdn.com/bootstrap/4.2.1/css/bootstrap.min.css"
			    :integrity "sha384-GJzZqFGwb1QTTN6wy59ffF1BuGJpLSa9DkKMp0DgiMDm4iYMj70gZWKYbI706tWS"
			    :crossorigin "anonymous"))
	(:script :src "https://cdnjs.cloudflare.com/ajax/libs/prefixfree/1.0.7/prefixfree.min.js"))
       (:body
	(:header
	 (:nav :class "navbar navbar-expand-md navbar-dark fixed-top bg-dark"
	       (:a :class "navbar-brand"
		   :href "https://github.com/atgreen/red-light-green-light" "Red Light Green Light")))
	(:main :role "main" :class "container"
	       (:div :class "row"
		     (:div :class "col"
	       (:div :style "width:100px"
		     (:div :class "rlgl-svg"))
	       (:h1 :class "mt-5" title)
	       (:a :href (format nil "~A/doc?id=~A" *server-uri* report-ref)
		   :target "_blank" "Original Report")
	       (:table :class "fold-table" :id "results"
		       (:tr (:th "RESULT") (:th "ID"))
		       (dolist (item results)
			 (let ((matcher (car item))
			       (alist (cdr item)))
			   (:tr :class "view" :class (kind matcher)
				(:td (kind matcher))
				(:td (:a :href (cdr (assoc :URL alist))
					 :target "_blank" (cdr (assoc :ID alist)))))
			   (:tr :class "fold"
				(:td :colspan "2")
				(:div :class "fold-content"
				      (when (and matcher
						 (not (eq (kind matcher) :unknown)))
					(let ((log-lines (log-entry matcher)))
					  (:div :id "border"
						(:a :href (format nil commit-url-format (githash matcher))
						    :target "_blank"
						    (:pre (str:trim (car log-lines))))
						(:pre (str:trim (format nil "~{~A~%~}" (cdr log-lines)))))
					  (:br)))
				      (:div :id "border"
					    (:pre (cl-json-util:pretty-json (json:encode-json-to-string alist)))))))))))))
	(:footer :class "fixed-bottom bg-light"
		 (:div :class "container"
		       (:span :class "text-muted" "Red Light Green Light (c) 2018, 2019 Anthony Green <green@moxielogic.com>"
			      )))
	(:script :attrs (list :src "https://code.jquery.com/jquery-3.3.1.slim.min.js"
			      :integrity "sha384-q8i/X+965DzO0rT7abK41JStQIAqVgRVzpbzo5smXKp4YfRvH+8abtTE1Pi6jizo"
			      :crossorigin "anonymous"))
	(:script :attrs (list :src "https://cdnjs.cloudflare.com/ajax/libs/popper.js/1.14.6/umd/popper.min.js"
			      :integrity "sha384-wHAiFfRlMFy6i5SRaxvfOCifBUQy1xHdJ/yoi7FRNXMRBu5WHdZYu1hA6ZOblgut"
			      :crossorigin "anonymous"))
	(:script :attrs (list :src "https://stackpath.bootstrapcdn.com/bootstrap/4.2.1/js/bootstrap.min.js"
			      :integrity "sha384-B0UglyR+jN6CkvvICOB2joaf5I4l3gm9GU6Hc1og6Ls7i6U/mkkaduKaBhlAXv9k"
			      :crossorigin "anonymous"))
	(:script :attrs (list :src "js/index.js"))))))
	      
;;; Read JSON pattern ---------------------------------------------------------

;; Read policy files.  Ignore all blank lines and comments, which are
;; lines starting with #, ; or -.  Each json matcher should be on a
;; single line of text.  Record the line number of each matcher along
;; with the matcher.

(defvar *policy* nil)

;;; HTTP SERVER CONTROL: ------------------------------------------------------
(defparameter *handler* nil)

(defun rlgl-root ()
  (fad:pathname-as-directory
   (make-pathname :name nil
                  :type nil
                  :defaults #.(or *compile-file-truename* *load-truename*))))

(defparameter *rlgl-dispatch-table*
  (list
   (hunchentoot:create-folder-dispatcher-and-handler
    "/images/" (fad:pathname-as-directory
                (make-pathname :name "images"
                               :defaults (rlgl-root))))
   (hunchentoot:create-folder-dispatcher-and-handler
    "/js/" (fad:pathname-as-directory
            (make-pathname :name "js"
                           :defaults (rlgl-root))))
   (hunchentoot:create-folder-dispatcher-and-handler
    "/css/" (fad:pathname-as-directory
            (make-pathname :name "css"
                           :defaults (rlgl-root))))
   (snooze:make-hunchentoot-app)))

(defclass exposer-acceptor (prom.tbnl:exposer hunchentoot:acceptor)
  ())

(defclass application (hunchentoot:easy-acceptor)
  ((exposer :initarg :exposer :reader application-metrics-exposer)
   (mute-access-logs :initform t :initarg :mute-access-logs :reader mute-access-logs)
   (mute-messages-logs :initform t :initarg :mute-error-logs :reader mute-messages-logs)))

(defmacro start-server (&key (handler '*handler*) (port 8080))
  "Initialize an HTTP handler"
  `(progn
     (setf snooze:*catch-errors* :verbose)
     (setf *print-pretty* nil)
     (setf hunchentoot:*dispatch-table* *rlgl-dispatch-table*)
     (setf prom:*default-registry* *rlgl-registry*)
     (let ((exposer (make-instance 'exposer-acceptor :registry *rlgl-registry* :port 9101)))
       (setf ,handler (hunchentoot:start (make-instance 'application
							:document-root #p"./"
							:port ,port
							:exposer exposer))))))

(defmacro stop-server (&key (handler '*handler*))
  "Shutdown the HTTP handler"
  `(hunchentoot:stop ,handler))

;;; END SERVER CONTROL --------------------------------------------------------

(defun initialize-policy-dir (dir)
  "Initialize the policy directory."
  (handler-case
      (truename (ensure-directories-exist dir))
    (error ()
      (log:error "Can't initialize policy directory ~A" dir)
      nil)))

(defun start-rlgl-server (arg)
  "Start the web application and have the main thread sleep forever,
  unless INTERACTIVE is nil."
  (setf hunchentoot:*show-lisp-errors-p* t)
  (setf hunchentoot:*show-lisp-backtraces-p* t)

  ;; Read the built-in configuration settings.
  (setf *config* (cl-toml:parse *default-config-text*))
  (log:info *default-config-text*)

  ;; FIXME: lookup storage driver
  ;; (setf *storage-driver (fixme-lookup (gethash "storage-driver" *config*)))
  (setf *server-uri* (gethash "server-uri" *config*))
  (log:info *server-uri*)

  ;; Set up DB 
  ;;
  (let ((db (gethash "db" *config*)))
    (alexandria:eswitch (db :test #'equal)
      ("sqlite"
       (let ((sqlite-db-filename (gethash "sqlite-db-filename" *config*)))
	 (if sqlite-db-filename
	     (rlgl.db:initialize :sqlite3
				 :sqlite-db-filename sqlite-db-filename)
	     (error "Missing sqlite-db-filename in rlgl.conf"))))))

  ;;
  ;; This is the directory where we check out policies.
  ;;
  (setf policy:*policy-dir* (pathname
			     (str:concat (gethash "policy-dir" *config*) "/")))
  (unless (initialize-policy-dir *policy-dir*)
    (sb-ext:quit))

  (setf *policy* (make-policy
		  "https://gogs-labdroid.apps.home.labdroid.net/green/test-policy.git"))

  (initialize-metrics)

  (let ((srvr (start-server)))
    ;; If ARG is NIL, then exit right away.  This is used by the
    ;; testsuite.
    (when arg
      (loop
	 (sleep 3000)))
    srvr))

(defun stop-rlgl-server ()
  "Stop the web application."
  (stop-server))

(defmethod hunchentoot:start ((app application))
  (hunchentoot:start (application-metrics-exposer app))
  (call-next-method))

(defmethod hunchentoot:stop ((app application) &key soft)
  (call-next-method)
  (hunchentoot:stop (application-metrics-exposer app) :soft soft))

(defmethod hunchentoot:acceptor-dispatch-request ((app application) request)
  (let ((labels (list (string-downcase (string (hunchentoot:request-method request)))
		      "rlgl_app")))
    (prom:counter.inc *http-requests-counter* :labels labels)
    (prom:histogram.time (prom:get-metric *http-request-duration* labels)
      (call-next-method))))
