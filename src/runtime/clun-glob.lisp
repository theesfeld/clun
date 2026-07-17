;;;; clun-glob.lisp -- the public Clun.Glob class and scan iterators.

(in-package :clun.runtime)

(defstruct (js-clun-glob
            (:include eng:js-object (class :glob))
            (:constructor %make-js-clun-glob))
  compiled)

(defun %glob-string-brand-p (value)
  (or (eng:js-string-p value)
      (and (eng:js-object-p value)
           (eq (eng:js-object-class value) :string))))

(defun %glob-string-argument (args operation)
  (when (null args)
    (eng:throw-native-error
     :error (format nil "~a: expected 1 arguments, got 0" operation)))
  (let ((value (eng:arg args 0)))
    (unless (%glob-string-brand-p value)
      (eng:throw-native-error
       :error (format nil "~a: first argument is not a string" operation)))
    ;; Boxed strings deliberately take the ordinary conversion path. This
    ;; observes overridden @@toPrimitive/toString/valueOf hooks.
    (eng:to-string value)))

(defun %require-clun-glob (value)
  (if (js-clun-glob-p value)
      value
      (eng:throw-type-error "Glob method called on an incompatible receiver")))

(defun %glob-option-value (options key)
  "Read KEY once, honoring custom prototypes but not Object.prototype pollution."
  (loop with object-prototype = (eng:intrinsic :object-prototype)
        with current = options
        do (when (eng::jm-get-own-property current key)
             (return (eng::jm-get current key options)))
           (let ((parent (eng::jm-get-prototype-of current)))
             (when (or (not (eng:js-object-p parent))
                       (eq parent object-prototype))
               (return eng:+undefined+))
             (setf current parent))))

(defun %glob-option-empty-p (value)
  (or (eng:js-nullish-p value)
      (and (eng:js-string-p value) (zerop (length value)))))

(defun %glob-option-flag (value default)
  (if (%glob-option-empty-p value)
      default
      (eq value eng:+true+)))

(defun %glob-resolve-cwd (value captured-cwd operation)
  (if (%glob-option-empty-p value)
      captured-cwd
      (progn
        (unless (%glob-string-brand-p value)
          (eng:throw-native-error
           :error (format nil "~a: invalid `cwd`, not a string" operation)))
        (let* ((converted (eng:to-string value))
               (native (clun.glob:glob-js-path-to-native converted)))
          (if (zerop (length native))
              captured-cwd
              (if (sys:absolute-path-p native)
                  (sys:normalize-path native)
                  (sys:normalize-path (sys:path-join captured-cwd native))))))))

(defun %glob-scan-options (args operation)
  (let* ((captured-cwd (sys:normalize-path (sys:current-directory)))
         (value (eng:arg args 0))
         (only-files t)
         (throw-broken nil)
         (follow nil)
         (absolute nil)
         (cwd captured-cwd)
         (dot nil))
    (cond
      ((or (null args) (eng:js-nullish-p value)) nil)
      ((eng:js-string-p value)
       (setf cwd (%glob-resolve-cwd value captured-cwd operation)))
      ((not (eng:js-object-p value))
       (eng:throw-native-error
        :error (format nil "~a: expected first argument to be an object" operation)))
      (t
       ;; Bun's parser has observable lookup order and reads each property once.
       (setf only-files
             (%glob-option-flag (%glob-option-value value "onlyFiles") only-files)
             throw-broken
             (%glob-option-flag (%glob-option-value value "throwErrorOnBrokenSymlink")
                                throw-broken)
             follow
             (%glob-option-flag (%glob-option-value value "followSymlinks") follow)
             absolute
             (%glob-option-flag (%glob-option-value value "absolute") absolute)
             cwd
             (%glob-resolve-cwd (%glob-option-value value "cwd") captured-cwd operation)
             dot
             (%glob-option-flag (%glob-option-value value "dot") dot))))
    (clun.glob:make-glob-scan-options
     :cwd cwd :dot dot :absolute absolute :follow-symlinks follow
     :throw-error-on-broken-symlink throw-broken :only-files only-files)))

(defun %glob-error-object (global condition)
  (typecase condition
    (sys:fs-error (%fs-error->js global condition))
    (t (eng:js-construct (eng:js-get global "Error")
                         (list (princ-to-string condition))))))

(defun %glob-scan-sync (glob args)
  (let ((options (%glob-scan-options args "scanSync")))
    (handler-case
        (eng:make-producer-generator
         (clun.glob:scan-glob (js-clun-glob-compiled glob) options))
      (sys:fs-error (condition)
        (eng:throw-js-value
         (%glob-error-object (eng:realm-global eng:*realm*) condition)))
      (clun.glob:glob-scan-cancelled ()
        (eng:make-producer-generator #()))
      (error (condition)
        (eng:throw-js-value
         (%glob-error-object (eng:realm-global eng:*realm*) condition))))))

(defun %glob-scan-async (glob args global realm)
  (let* ((options (%glob-scan-options args "scan"))
         (token (clun.glob:make-glob-scan-token))
         (job nil)
         (generator nil)
         (loop (eng:current-loop)))
    (setf generator
          (eng:make-producer-async-generator
           :cancel (lambda ()
                     (clun.glob:cancel-glob-scan token)
                     (when job (lp:cancel-worker-job job)))))
    (setf job
          (lp:worker-submit-cancellable
           loop
           (lambda (worker-token)
             (clun.glob:scan-glob
              (js-clun-glob-compiled glob) options
              (lambda ()
                (or (clun.glob:glob-scan-cancelled-p token)
                    (lp:worker-cancelled-p worker-token)))))
           (lambda (result)
             ;; Completion executes on the realm's event-loop thread. A producer
             ;; cleared by return()/throw() discards this late commit.
             (let ((eng:*realm* realm))
               (case (first result)
                 (:ok (eng:async-generator-producer-ready generator (second result)))
                 (:err
                  (eng:async-generator-producer-failed
                   generator (%glob-error-object global (second result))))
                 (:cancelled
                  (eng:async-generator-producer-cancelled generator)))))))
    generator))

(defun install-clun-glob (clun global realm)
  "Install the realm-local Clun.Glob constructor and exact prototype shape."
  (let* ((prototype (eng:new-object))
         (constructor nil))
    ;; Own prototype keys are intentionally inserted in Bun's observable order.
    (eng::obj-set-desc
     prototype "match"
     (eng::data-pd
      (eng:make-native-function
       "match" 1
       (lambda (this args)
         (let ((glob (%require-clun-glob this)))
           (eng:js-boolean
            (clun.glob:glob-match-p
             (js-clun-glob-compiled glob)
             (%glob-string-argument args "Glob.matchString"))))))
      :writable t :enumerable t :configurable nil))
    (eng::obj-set-desc
     prototype "scan"
     (eng::data-pd
      (eng:make-native-function
       "" 1
       (lambda (this args)
         (%glob-scan-async (%require-clun-glob this) args global realm)))
      :writable t :enumerable t :configurable t))
    (eng::obj-set-desc
     prototype "scanSync"
     (eng::data-pd
      (eng:make-native-function
       "" 1
       (lambda (this args)
         (%glob-scan-sync (%require-clun-glob this) args)))
      :writable t :enumerable t :configurable t))
    (setf constructor
          (eng:make-native-function
           "Glob" 0
           (lambda (this args)
             (declare (ignore this args))
             (eng:throw-type-error
              "Glob constructor cannot be invoked without 'new'"))
           :construct
           (lambda (args new-target)
             (%make-js-clun-glob
              :proto (eng::nt-prototype new-target prototype)
              :compiled (clun.glob:compile-glob
                         (%glob-string-argument args "Glob.constructor"))))))
    (eng::obj-set-desc prototype "constructor"
                       (eng::data-pd constructor :writable t :enumerable nil
                                                :configurable t))
    (eng::obj-set-desc prototype (eng:well-known :to-string-tag)
                       (eng::data-pd "Glob" :writable nil :enumerable nil
                                           :configurable t))
    (eng::obj-set-desc constructor "prototype"
                       (eng::data-pd prototype :writable nil :enumerable nil
                                              :configurable nil))
    (eng::obj-set-desc clun "Glob"
                       (eng::data-pd constructor :writable t :enumerable t
                                               :configurable nil))
    constructor))
