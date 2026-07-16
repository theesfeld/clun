#!/usr/bin/env sbcl --script

(require :sb-bsd-sockets)

(defun fail (format-control &rest arguments)
  (apply #'format *error-output* format-control arguments)
  (terpri *error-output*)
  (sb-ext:exit :code 1))

(defun octet-length (string)
  (length (sb-ext:string-to-octets string :external-format :latin-1)))

(defun request-string (&rest lines)
  (with-output-to-string (stream)
    (dolist (line lines)
      (write-string line stream)
      (write-char #\Return stream)
      (write-char #\Newline stream))
    (write-char #\Return stream)
    (write-char #\Newline stream)))

(defun transact (port pieces)
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket
                               :type :stream :protocol :tcp)))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-connect
            socket (sb-bsd-sockets:make-inet-address "127.0.0.1") port)
           (let ((stream (sb-bsd-sockets:socket-make-stream
                          socket :input t :output t :element-type 'character
                          :external-format :latin-1 :buffering :none)))
             (dolist (piece pieces)
               (write-string piece stream)
               (force-output stream)
               (sleep 0.02))
             (handler-case
                 (sb-ext:with-timeout 5
                   (with-output-to-string (output)
                     (loop for character = (read-char stream nil nil)
                           while character do (write-char character output))))
               (sb-ext:timeout () (fail "raw HTTP response timed out")))))
      (ignore-errors (sb-bsd-sockets:socket-close socket)))))

(defun contains (haystack needle label)
  (unless (search needle haystack)
    (fail "~a: missing ~s in ~s" label needle haystack)))

(defun status-is (response code label)
  (contains response (format nil "HTTP/1.1 ~d " code) label))

(let* ((port-text (sb-ext:posix-getenv "CLUN_COOKIE_RAW_PORT"))
       (port (and port-text (parse-integer port-text :junk-allowed nil))))
  (unless (and port (<= 1 port 65535)) (fail "invalid raw HTTP port"))

  (let ((response
          (transact port
                    (list (request-string "GET /cookies HTTP/1.1" "Host: x"
                                          "Cookie: a=1" "Cookie: b=2"
                                          "Connection: close")))))
    (status-is response 200 "duplicate Cookie")
    (contains response "cookie=a=1; b=2|a=1|b=2" "duplicate Cookie"))

  (let* ((headers (request-string "POST /echo HTTP/1.1" "Host: x"
                                  "Content-Length: 4, 4" "Content-Length: 4"
                                  "Connection: close"))
         (response (transact port (list (concatenate 'string headers "body")))))
    (status-is response 200 "identical Content-Length")
    (contains response "echo=body" "identical Content-Length"))

  (dolist
      (case
       (list
        (list "TE plus CL"
              (concatenate 'string
                           (request-string "POST /echo HTTP/1.1" "Host: x"
                                           "Transfer-Encoding: chunked"
                                           "Content-Length: 4" "Connection: close")
                           (format nil "4~c~cbody~c~c0~c~c~c~c"
                                   #\Return #\Newline #\Return #\Newline
                                   #\Return #\Newline #\Return #\Newline)))
        (list "duplicate Transfer-Encoding"
              (concatenate 'string
                           (request-string "POST /echo HTTP/1.1" "Host: x"
                                           "Transfer-Encoding: chunked"
                                           "Transfer-Encoding: chunked"
                                           "Connection: close")
                           (format nil "0~c~c~c~c"
                                   #\Return #\Newline #\Return #\Newline)))
        (list "mismatched Content-Length"
              (request-string "POST /echo HTTP/1.1" "Host: x"
                              "Content-Length: 4" "Content-Length: 5"
                              "Connection: close"))))
    (status-is (transact port (list (second case))) 400 (first case)))

  (let ((response
          (transact port
                    (list (request-string "GET /cookies HTTP/1.1" "Host: x"
                                          "Connection: keep-alive"
                                          "Connection: upgrade, close")))))
    (status-is response 200 "Connection close precedence"))

  (let* ((prefix (format nil "GET /limit HTTP/1.1~c~cX-Pad: "
                         #\Return #\Newline))
         (suffix (format nil "~c~cConnection: close~c~c~c~c"
                         #\Return #\Newline #\Return #\Newline
                         #\Return #\Newline))
         (padding (- 16384 (octet-length prefix) (octet-length suffix)))
         (exact (concatenate 'string prefix (make-string padding :initial-element #\a)
                             suffix))
         (over (concatenate 'string prefix (make-string (1+ padding) :initial-element #\a)
                            suffix)))
    (unless (= 16384 (octet-length exact)) (fail "exact header fixture length drift"))
    (status-is (transact port (list exact)) 200 "exact one-feed header limit")
    (status-is (transact port (list (subseq exact 0 (- (length exact) 3))
                                    (subseq exact (- (length exact) 3))))
               200 "exact split-feed header limit")
    (status-is (transact port (list over)) 431 "over one-feed header limit")
    (status-is (transact port (list (subseq over 0 (- (length over) 3))
                                    (subseq over (- (length over) 3))))
               431 "over split-feed header limit"))

  (let* ((wire
           (concatenate 'string
                        (request-string "GET /slow HTTP/1.1" "Host: x")
                        (request-string "GET /fast HTTP/1.1" "Host: x"
                                        "Connection: close")))
         (response (transact port (list wire)))
         (first (search "first" response))
         (second (search "second" response)))
    (unless (and first second (< first second))
      (fail "pipeline response order mismatch: ~s" response)))

  (status-is
   (transact port
             (list (request-string "GET /throw HTTP/1.1" "Host: x"
                                   "Connection: close")))
   500 "default error response")

  (format t "web.cookies raw-http ok~%"))
