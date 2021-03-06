;;; -*- Mode: LISP; Syntax: COMMON-LISP; Package: RLGL-SERVER; Base: 10 -*-
;;;
;;; Copyright (C) 2018, 2019, 2020  Anthony Green <green@moxielogic.com>
;;;                         
;;; This program is free software: you can redistribute it and/or
;;; modify it under the terms of the GNU Affero General Public License
;;; as published by the Free Software Foundation, either version 3 of
;;; the License, or (at your option) any later version.
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; Affero General Public License for more details.
;;;
;;; You should have received a copy of the GNU Affero General Public
;;; License along with this program.  If not, see
;;; <http://www.gnu.org/licenses/>.

;; Matcher routines

(in-package #:matcher)

(defclass policy-matcher ()
  ((kind            :initarg :kind            :reader kind)
   (githash         :initarg :githash         :reader githash)
   (lineno          :initarg :lineno          :reader lineno)
   (matcher         :initarg :matcher         :reader matcher)
   (expiration-date :initarg :expiration-date :reader expiration-date)
   (log-entry :reader log-entry)))

(defun make-policy-matcher (&key kind (githash nil)
			      (lineno 0)
			      (matcher nil)
			      expiration-date)
  (make-instance 'policy-matcher
		 :kind kind
		 :githash githash
		 :lineno lineno
		 :matcher matcher
		 :expiration-date expiration-date))

(defun match-pair-in-alist (pair alist)
  "Given a cons PAIR, return non-NIL if PAIR matches in ALIST using
the function stored in the CDR of PAIR."
  (let ((c (assoc (car pair) alist)))
    (and c (apply (cdr pair) (list (cdr c))))))

(defun match-candidate-pattern (candidate pattern)
  "Given a CANDIDATE alist, return T if PATTERN matches CANDIDATE."
  (not (find-if-not (lambda (v)
		      (match-pair-in-alist v candidate))
		    pattern)))
