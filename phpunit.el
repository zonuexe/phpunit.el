;;; phpunit.el --- Launch PHP unit tests using phpunit

;; Author: Nicolas Lamirault <nicolas.lamirault@gmail.com>
;;         Eric Hansen <hansen.c.eric@gmail.com>
;;
;; URL: https://github.com/nlamirault/phpunit.el
;; Version: 0.12.0
;; Keywords: php, tests, phpunit

;; Package-Requires: ((s "1.9.0") (f "0.16.0") (pkg-info "0.5") (cl-lib "0.5") (emacs "24.3"))

;;; License:

;; Copyright (C) 2014-2016 Nicolas Lamirault <nicolas.lamirault@gmail.com>

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 2
;; of the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
;; 02110-1301, USA.

;;; Commentary:

;; Thanks to tox.el(https://github.com/chmouel/tox.el) from Chmouel Boudjnah.

;; To use this code, bind the functions `phpunit-current-test', `phpunit-current-class',
;; and `phpunit-current-project' to convenient keys with something like :

;; (define-key web-mode-map (kbd "C-x t") 'phpunit-current-test)
;; (define-key web-mode-map (kbd "C-x c") 'phpunit-current-class)
;; (define-key web-mode-map (kbd "C-x p") 'phpunit-current-project)

;;; Code:

(require 'cl-lib)
(require 's)
(require 'f)
(eval-when-compile
  (require 'rx))

(defgroup phpunit nil
  "PHPUnit utility"
  :group 'php)

(defcustom phpunit-program "phpunit"
  "PHPUnit binary path."
  :type 'file
  :group 'phpunit)

(defcustom phpunit-arg ""
  "Argument to pass to phpunit."
  :type 'string
  :group 'phpunit)

(defcustom phpunit-stop-on-error nil
  "Stop execution upon first error."
  :type 'boolean
  :group 'phpunit)

(defcustom phpunit-stop-on-failure nil
  "Stop execution upon first error or failure."
  :type 'boolean
  :group 'phpunit)

(defcustom phpunit-stop-on-skipped nil
  "Stop execution upon first skipped test."
  :type 'boolean
  :group 'phpunit)

(defcustom phpunit-verbose-mode nil
  "Display debugging information during test execution."
  :type 'boolean
  :group 'phpunit)

(defcustom phpunit-configuration-file nil
  "The PHPUnit configuration file."
  :type '(choice string nil)
  :group 'phpunit)

(defconst php-beginning-of-defun-regexp
  (eval-when-compile
    (rx line-start
        (* (syntax whitespace))
        (* (or "abstract" "final" "private" "protected" "public" "static"))
        "function"
        (+ (syntax whitespace))
        (? "&")
        (group (+ (or (syntax word) (syntax symbol))))
        (* (syntax whitespace))
        "("))
  "Regular expression for a PHP function.")

(defconst php-beginning-of-class
  "^\\s-*class\\s-+&?\\([a-zA-Z_\x7f-\xff][a-zA-Z0-9_\x7f-\xff]*\\)"
  "Regular expression for a PHP class.")

(defconst php-labelchar-regexp
  "[a-zA-Z_\x7f-\xff][a-zA-Z0-9_\x7f-\xff]"
  "Valid syntax for a character in a PHP label.")

;; Allow for error navigation after a failed test
(add-hook 'compilation-mode-hook
          (lambda ()
            (interactive)
            (add-to-list 'compilation-error-regexp-alist '("^\\(.+\\.php\\):\\([0-9]+\\)$" 1 2))))

(defvar phpunit-last-group-cache nil)

;; Commands
;; -----------

(defun phpunit-get-program (args)
  "Return the command to launch unit test.
`ARGS' corresponds to phpunit command line arguments."
  (let ((phpunit-executable nil)
        (filename (or (buffer-file-name) "")))
    (setq phpunit-executable
          (or (executable-find "phpunit")
              (concat (locate-dominating-file "" "vendor")
                  "vendor/bin/phpunit")))
    ;; (setq phpunit-executable
    ;;       (concat (locate-dominating-file filename "vendor")
    ;;               "vendor/bin/phpunit"))
    (unless phpunit-executable
      (setq phpunit-executable phpunit-program))
    (when (file-remote-p phpunit-executable)
      (setq phpunit-executable
            (tramp-file-name-localname (tramp-dissect-file-name phpunit-executable))))
    (s-concat phpunit-executable
              (if phpunit-configuration-file
                  (s-concat " -c " phpunit-configuration-file)
                "")
              " "
              args)))

(defun phpunit-get-root-directory ()
  "Return the root directory to run tests."
  ;; The function doesn't detect the root directory when used with
  ;; tramp mode. In that case, the phpunit-root-directory variable can
  ;; be set which takes precedence
  (if (boundp 'phpunit-root-directory)
      phpunit-root-directory
    (let ((filename (buffer-file-name)) path)
      (cond
       ((null filename) default-directory)
       (phpunit-configuration-file
        (file-truename (locate-dominating-file filename phpunit-configuration-file)))
       (:else
        (cl-loop for file in '("phpunit.xml" "phpunit.xml.dist" ".git" "composer.json")
                 do (setq path (locate-dominating-file filename file))
                 if path return (file-truename path)
                 finally return (file-truename "./")))))))

(defun phpunit-get-current-class (&optional class-or-path)
  "Return the canonical unit test class name associated with the current class or buffer."
  (let ((class-name
	 (let ((class-or-filename (f-filename (or class-or-path
						  (save-excursion (re-search-backward php-beginning-of-class 0 t)
								  (match-string 1))
						  (buffer-file-name)))))
	   (string-match (concat "\\(" php-labelchar-regexp "*\\)")
			 class-or-filename)
	   (match-string 1 class-or-filename))))
    (if (string-match "Test$" class-name)
	class-name
      (concat class-name "Test"))))

(defun phpunit-get-current-test ()
  "Get the name of the current test function"
  (save-excursion
    (when (re-search-backward php-beginning-of-defun-regexp nil t)
      (match-string-no-properties 1))))

(defun phpunit--listing-groups ()
  "Return list of @group.

https://phpunit.de/manual/current/en/appendixes.annotations.html#appendixes.annotations.group"
  (let ((phpunit-output (phpunit--execute "--list-groups")))
    (with-temp-buffer
      (insert phpunit-output)
      (goto-char (point-min))
      (search-forward "Available test group")
      (move-beginning-of-line 1)
      (next-line)
      (cl-loop
       for line in (s-split "\n" (buffer-substring-no-properties (point) (point-max)))
       if (s-starts-with? " - " line)
       collect (s-chop-prefix " - " line)))))

(defun phpunit--get-last-group (path)
  "Get last group cache by `PATH'."
  (unless phpunit-last-group-cache
    (setq phpunit-last-group-cache (make-hash-table :test 'equal)))
  (gethash path phpunit-last-group-cache nil))

(defun phpunit--put-last-group (group path)
  "Put last group `GROUP' cache by `PATH'."
  (unless phpunit-last-group-cache
    (setq phpunit-last-group-cache (make-hash-table :test 'equal)))
  (puthash path group phpunit-last-group-cache))

(defun phpunit-arguments (args)
  (let ((opts args))
     (when phpunit-stop-on-error
       (setq opts (s-concat opts " --stop-on-error")))
     (when phpunit-stop-on-failure
       (setq opts (s-concat opts " --stop-on-failure")))
     (when phpunit-stop-on-skipped
       (setq opts (s-concat opts " --stop-on-skipped")))
     (when phpunit-verbose-mode
       (setq opts (s-concat opts " --verbose")))
     opts))

(defun phpunit-get-compile-command (args)
  (let ((column-setting-command (format "stty cols %d" (frame-width)))
        (command-separator "; ")
        (phpunit-command (phpunit-get-program (phpunit-arguments args))))
    (concat column-setting-command command-separator phpunit-command)))

(defun phpunit--execute (args)
  "Execute phpunit command with `ARGS'."
  (let ((default-directory (phpunit-get-root-directory)))
    (shell-command-to-string (phpunit-get-program (phpunit-arguments args)))))

(defun phpunit-run (args)
  "Execute phpunit command with `ARGS'."
  (let ((default-directory (phpunit-get-root-directory)))
    (compile (phpunit-get-compile-command args))))


;; API
;; ----

;;;###autoload
(defun phpunit-current-test ()
  "Launch PHPUnit on curent test."
  (interactive)
  (let ((args (s-concat " --filter '"
			(phpunit-get-current-class)
			"::"
			(phpunit-get-current-test) "'")))
    (phpunit-run args)))


;;;###autoload
(defun phpunit-current-class ()
  "Launch PHPUnit on current class."
  (interactive)
  (phpunit-run (s-chop-prefix (phpunit-get-root-directory) buffer-file-name)))

;;;###autoload
(defun phpunit-current-project ()
  "Launch PHPUnit on current project."
  (interactive)
  (phpunit-run ""))

;;;###autoload
(defun phpunit-group (use-last-group &optional group)
  "Launch PHPUnit for group."
  (interactive "p")
  (let* ((current-root-directory (phpunit-get-root-directory))
         (last-group (phpunit--get-last-group current-root-directory)))
    (when (called-interactively-p 'interactive)
      (setq use-last-group (eq use-last-group 1))
      (setq group (if (and use-last-group last-group)
                      last-group
                    (completing-read "PHPUnit @group: " (phpunit--listing-groups)))))
    (phpunit-run (format "--group %s" group))
    (phpunit--put-last-group group current-root-directory)))

(provide 'phpunit)
;;; phpunit.el ends here
