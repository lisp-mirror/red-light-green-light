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

(defpackage #:rlgl.util
  (:use #:cl)
  (:shadow #:package)
  (:export #:random-hex-string #:valid-url? #:read-file-into-string))

(in-package #:rlgl.util)

(setf *random-state* (make-random-state t))

(defun random-hex-string (&optional (length 7))
  (let ((chars "abcdef0123456789"))
    (coerce (loop repeat length collect (aref chars (random (length chars))))
            'string)))

(defun read-file-into-string (filename)
  (with-open-file (stream filename :external-format :UTF-8)
    (let ((contents (make-string (file-length stream))))
      (read-sequence contents stream)
      contents)))

(defun valid-url? (string)
  "Returns T if STRING is a valid http or https url."
  (and string
       (quri:uri-http-p (quri:uri string))))
