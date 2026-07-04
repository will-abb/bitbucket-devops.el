;;; bitbucket-devops-pull-requests-ui-test.el --- Tests for PR UI buffers -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Code:

(require 'ert)
(require 'json)
(require 'cl-lib)
(require 'bitbucket-devops-pull-requests-ui)

(defconst bitbucket-devops-pull-requests-ui-test-fixtures-directory
  (expand-file-name
   "fixtures"
   (file-name-directory (or load-file-name buffer-file-name)))
  "Directory containing sanitized pull request UI fixtures.")

(defun bitbucket-devops-pull-requests-ui-test-read-json-fixture (name)
  "Return JSON fixture NAME parsed as an alist."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name name bitbucket-devops-pull-requests-ui-test-fixtures-directory))
    (json-parse-buffer
     :object-type 'alist
     :array-type 'list
     :null-object nil
     :false-object nil)))

(defun bitbucket-devops-pull-requests-ui-test-read-text-fixture (name)
  "Return text fixture NAME as a string."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name name bitbucket-devops-pull-requests-ui-test-fixtures-directory))
    (buffer-string)))

(ert-deftest bitbucket-devops-pull-requests-ui-row-renders-summary-columns ()
  (let* ((page
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-requests-page-1.json"))
         (pull-request (car (alist-get 'values page))))
    (should
     (equal
      (bitbucket-devops-pull-requests-ui--row pull-request)
      '("11"
        ["11"
         "MERGED"
         "Development"
         "development"
         "master"
         "Will Bosch"
         "2"
         "1"
         ""
         "2026-04-28 09:10"
         "2026-04-28 10:30"])))))

(ert-deftest bitbucket-devops-pull-requests-ui-row-marks-drafts ()
  (let* ((page
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-requests-page-1.json"))
         (pull-request (cadr (alist-get 'values page))))
    (should
     (equal
      (aref (cadr (bitbucket-devops-pull-requests-ui--row pull-request)) 1)
      "OPEN DRAFT"))))

(ert-deftest bitbucket-devops-pull-requests-ui-row-uses-semantic-faces ()
  (let* ((page
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-requests-page-1.json"))
         (pull-request (car (alist-get 'values page)))
         (columns (cadr (bitbucket-devops-pull-requests-ui--row pull-request))))
    (should
     (eq (get-text-property 0 'face (aref columns 0))
         'bitbucket-devops-pull-requests-id-face))
    (should
     (eq (get-text-property 0 'face (aref columns 1))
         'bitbucket-devops-pull-requests-merged-face))
    (should
     (eq (get-text-property 0 'face (aref columns 2))
         'bitbucket-devops-pull-requests-title-face))
    (should
     (eq (get-text-property 0 'face (aref columns 3))
         'bitbucket-devops-pull-requests-source-branch-face))
    (should
     (eq (get-text-property 0 'face (aref columns 4))
         'bitbucket-devops-pull-requests-destination-branch-face))
    (should
     (eq (get-text-property 0 'face (aref columns 5))
         'bitbucket-devops-pull-requests-author-face))))

(ert-deftest bitbucket-devops-pull-requests-ui-build-summary-label-prioritizes-actionable-state ()
  (should
   (equal
    (bitbucket-devops-pull-requests-ui--build-summary-label nil)
    "No builds"))
  (should
   (equal
    (bitbucket-devops-pull-requests-ui--build-summary-label
     '(((state . "SUCCESSFUL")) ((state . "FAILED"))))
    "1 failed"))
  (should
   (equal
    (bitbucket-devops-pull-requests-ui--build-summary-label
     '(((state . "SUCCESSFUL")) ((state . "INPROGRESS"))))
    "1 running"))
  (should
   (equal
    (bitbucket-devops-pull-requests-ui--build-summary-label
     '(((state . "SUCCESSFUL")) ((state . "SUCCESSFUL"))))
    "2 passed")))

(ert-deftest bitbucket-devops-pull-requests-ui-details-show-review-counts-and-names ()
  (let* ((page
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-requests-page-1.json"))
         (pull-request (car (alist-get 'values page))))
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request pull-request)
      (bitbucket-devops-pull-requests-ui--render-details)
      (let ((contents (buffer-string)))
        (should
         (string-match-p "Approvals:[[:space:]]+1 / 2" contents))
        (should
         (string-match-p
          "Reviewers:[[:space:]]+Ada Reviewer, Grace Reviewer"
          contents))
        (should
         (string-match-p
          "Approved by:[[:space:]]+Ada Reviewer"
          contents))))))

(ert-deftest bitbucket-devops-pull-requests-ui-details-render-string-description ()
  (let ((pull-request
         '((id . 2)
           (title . "Test")
           (state . "OPEN")
           (draft . t)
           (description . "test")
           (source . ((branch . ((name . "test")))))
           (destination . ((branch . ((name . "main")))))
           (author . ((display_name . "Will Bosch"))))))
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request pull-request)
      (bitbucket-devops-pull-requests-ui--render-details)
      (should
       (string-match-p
        "[-]\\{20,\\}\nDescription\n[-]\\{20,\\}\ntest\n"
        (buffer-string)))
      (should (string-match-p "Readiness:[[:space:]]+Draft"
                              (buffer-string))))))

(ert-deftest bitbucket-devops-pull-requests-ui-fontifies-markdown-description ()
  (cl-letf (((symbol-function 'require)
             (lambda (feature &optional _filename _noerror)
               (eq feature 'markdown-mode)))
            ((symbol-function 'markdown-mode)
             (lambda ()
               (save-excursion
                 (goto-char (point-min))
                 (add-face-text-property
                  (point)
                  (line-end-position)
                  'font-lock-keyword-face)))))
    (let* ((rendered
            (bitbucket-devops-pull-requests-ui--fontify-markdown
             "# Summary\n\nBody"))
           (heading-face (get-text-property 0 'face rendered))
           (body-face
            (get-text-property (string-match-p "Body" rendered) 'face rendered)))
      (should (equal (substring-no-properties rendered) "# Summary\n\nBody"))
      (should (memq 'font-lock-keyword-face (ensure-list heading-face)))
      (should
       (memq
        'bitbucket-devops-pull-requests-description-face
        (ensure-list heading-face)))
      (should
       (memq
        'bitbucket-devops-pull-requests-description-face
        (ensure-list body-face))))))

(ert-deftest bitbucket-devops-pull-requests-ui-details-use-visual-hierarchy ()
  (let* ((page
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-requests-page-1.json"))
         (pull-request (car (alist-get 'values page))))
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request pull-request)
      (bitbucket-devops-pull-requests-ui--render-details)
      (let ((header
             (apply #'concat
                    (bitbucket-devops-pull-requests-ui--detail-header-line))))
        (should (string-match-p "williseed1/test" header))
        (should (string-match-p "PR #11" header))
        (should (string-match-p "development -> master" header)))
      (goto-char (point-min))
      (should
       (eq (get-text-property (point) 'face)
           'bitbucket-devops-pull-requests-id-face))
      (search-forward "Development")
      (should
       (eq (get-text-property (match-beginning 0) 'face)
           'bitbucket-devops-pull-requests-heading-face))
      (search-forward "Description")
      (should
       (eq (get-text-property (match-beginning 0) 'face)
           'bitbucket-devops-pull-requests-section-face))
      (search-forward "No description.")
      (should
	      (eq (get-text-property (match-beginning 0) 'face)
	          'bitbucket-devops-pull-requests-empty-face)))))

(ert-deftest bitbucket-devops-pull-requests-ui-list-header-shows-context-and-filters ()
  (let* ((page
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-requests-page-1.json"))
         (pull-requests (alist-get 'values page)))
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (setq-local bitbucket-devops-pull-requests-ui--pull-requests pull-requests)
      (setq-local bitbucket-devops-pull-requests-ui--state-filter "OPEN")
      (setq-local bitbucket-devops-pull-requests-ui--branch-filter "main")
      (bitbucket-devops-pull-requests-ui--render)
      (let ((header (apply #'concat
                           (bitbucket-devops-pull-requests-ui--list-header-line))))
        (should (string-match-p "williseed1/test" header))
        (should (string-match-p "1 visible / 2 loaded" header))
        (should (string-match-p "State: OPEN" header))
        (should (string-match-p "Branch: main" header)))
      (goto-char (point-min))
      (should (string-match-p "williseed1/test" (thing-at-point 'line t)))
      (forward-line 1)
      (should (string-match-p "#[[:space:]]+State[[:space:]]+Title"
                              (thing-at-point 'line t))))))

(ert-deftest bitbucket-devops-pull-requests-ui-render-preserves-visible-scroll ()
  (let ((buffer
         (generate-new-buffer
          " *bitbucket-devops-pull-requests-scroll-test*")))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (bitbucket-devops-pull-requests-list-mode)
          (setq-local bitbucket-devops-pull-requests-ui--context
                      '(:workspace "williseed1" :repo-slug "test"))
          (setq-local
           bitbucket-devops-pull-requests-ui--pull-requests
           (cl-loop
            for id from 1 to 40
            collect
            `((id . ,id)
              (title . ,(format "Pull request %02d" id))
              (state . "OPEN")
              (source . ((branch . ((name . "feature")))))
              (destination . ((branch . ((name . "main")))))
              (author . ((display_name . "Will Bosch")))
              (created_on . "2026-04-28T14:10:00.000000+00:00")
              (updated_on . "2026-04-28T15:10:00.000000+00:00")))))
          (bitbucket-devops-pull-requests-ui--render)
          (goto-char (point-min))
          (forward-line 12)
          (set-window-point (selected-window) (point))
          (set-window-start (selected-window) (point))
          (let ((start-line (line-number-at-pos (window-start))))
            (bitbucket-devops-pull-requests-ui--render)
            (should (= (line-number-at-pos (window-start)) start-line)))
      (kill-buffer buffer))))

(ert-deftest bitbucket-devops-pull-requests-ui-comments-use-thread-formatting ()
  (let* ((pull-request
          (copy-tree
           (car
            (alist-get
             'values
             (bitbucket-devops-pull-requests-ui-test-read-json-fixture
              "pull-requests-page-1.json")))))
         (comments
          (alist-get
           'values
           (bitbucket-devops-pull-requests-ui-test-read-json-fixture
            "pull-request-comments.json"))))
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request pull-request)
      (setq-local bitbucket-devops-pull-requests-ui--details-comments comments)
      (bitbucket-devops-pull-requests-ui--render-details)
      (let ((text (buffer-string)))
        (should
         (< (string-match-p "#102" text)
            (string-match-p "#101" text)))
        (should (string-match-p "\n    [-]\\{20,\\}\n    |-- #102" text))
        (should (string-match-p "\n[-]\\{20,\\}\no #101" text)))
      (goto-char (point-min))
      (search-forward "#101")
      (should
       (eq (get-text-property (match-beginning 0) 'face)
           'bitbucket-devops-pull-requests-comment-id-face))
      (search-forward "2026-04-28 09:20")
      (should
       (eq (get-text-property (match-beginning 0) 'face)
           'bitbucket-devops-pull-requests-secondary-face))
      (should (string-match-p "|-- #102 Will Bosch: Yes" (buffer-string))))))

(ert-deftest bitbucket-devops-pull-requests-ui-comments-display-emoji-shortcodes ()
  (let* ((raw
          (concat
           "| :white_check_mark: | Open Source Security | 0 |\n\n"
           ":computer: Catch issues earlier. :custom_status:"))
         (comment
          `((id . 501)
            (content . ((raw . ,raw)))
            (user . ((display_name . "Snyk")))))
         (pull-request
          '((id . 2)
            (title . "Test")
            (state . "OPEN")
            (description . "test")
            (source . ((branch . ((name . "feature")))))
            (destination . ((branch . ((name . "main")))))
            (author . ((display_name . "Will Bosch"))))))
    (let ((bitbucket-devops-pull-requests-display-emoji-shortcodes t)
          (bitbucket-devops-pull-requests-ui--emoji-shortcodes nil))
      (with-temp-buffer
        (bitbucket-devops-pull-requests-detail-mode)
        (setq-local
         bitbucket-devops-pull-requests-ui--details-pull-request pull-request)
        (setq-local bitbucket-devops-pull-requests-ui--details-comments
                    (list comment))
        (setq-local bitbucket-devops-pull-requests-ui--details-activity
                    `(((comment . ,comment))))
        (bitbucket-devops-pull-requests-ui--render-details)
        (let ((contents (buffer-string)))
          (should (string-match-p "✅" contents))
          (should (string-match-p "💻" contents))
          (should (string-match-p ":custom_status:" contents))
          (should-not (string-match-p ":white_check_mark:" contents))
          (should-not (string-match-p ":computer:" contents))))
      (should
       (equal (bitbucket-devops-pull-requests-comment-text comment) raw)))))

(ert-deftest bitbucket-devops-pull-requests-ui-can-disable-comment-emoji-shortcodes ()
  (let ((bitbucket-devops-pull-requests-display-emoji-shortcodes nil))
    (should
     (equal
      (bitbucket-devops-pull-requests-ui--display-comment-text
       ":white_check_mark: :computer:")
      ":white_check_mark: :computer:"))))

(ert-deftest bitbucket-devops-pull-requests-ui-detail-errors-name-the-section ()
  (let (reported)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq reported (apply #'format format-string args)))))
        (bitbucket-devops-pull-requests-ui--details-receive
         (current-buffer)
         'bitbucket-devops-pull-requests-ui--details-diffstat
         nil
         '(:message "Not found")
         "changed files")))
    (should
     (equal
      reported
      "Unable to load Bitbucket pull request changed files: Not found"))))

(ert-deftest bitbucket-devops-pull-requests-ui-enriches-comment-resolution-state ()
  (let* ((context '(:workspace "williseed1" :repo-slug "test"))
         (comments
          (list
           '((id . 101)
             (content . ((raw . "Please fix this"))))
           '((id . 102)
             (parent . ((id . 101)))
             (content . ((raw . "Done"))))))
         enriched)
    (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-get-comment)
               (lambda (_context _pull-request-id comment-id callback)
                 (funcall
                  callback
                  `((id . ,comment-id)
                    (resolution . ((type . "comment_resolution"))))
                  nil))))
      (bitbucket-devops-pull-requests-ui--enrich-comment-resolutions
       context
       11
       comments
       (lambda (value _error)
         (setq enriched value))))
    (should (bitbucket-devops-pull-requests-comment-resolved-p (car enriched)))
    (should-not (bitbucket-devops-pull-requests-comment-resolved-p (cadr enriched)))))

(ert-deftest bitbucket-devops-pull-requests-ui-mode-uses-custom-column-widths ()
  (let ((bitbucket-devops-pull-requests-list-column-widths
         '((number . 4)
           (state . 9)
           (title . 40)
           (source . 12)
           (destination . 12)
           (author . 20)
           (reviewers . 8)
           (approvals . 9)
           (builds . 7)
           (created . 17)
           (updated . 18))))
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (should
       (equal
        (mapcar #'cadr
                (append tabulated-list-format nil))
        '(4 9 40 12 12 20 8 9 7 17 18))))))

(ert-deftest bitbucket-devops-pull-requests-ui-list-mode-disables-line-wrapping ()
  (with-temp-buffer
    (visual-line-mode 1)
    (setq-local truncate-lines nil)
    (setq-local word-wrap t)
    (bitbucket-devops-pull-requests-list-mode)
    (should-not tabulated-list-use-header-line)
    (should truncate-lines)
    (should-not word-wrap)
    (should-not visual-line-mode)))

(ert-deftest bitbucket-devops-pull-requests-ui-list-mode-can-allow-line-wrapping ()
  (let ((bitbucket-devops-pull-requests-list-truncate-lines nil))
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (visual-line-mode 1)
      (setq-local truncate-lines t)
      (bitbucket-devops-pull-requests-ui--apply-list-line-wrapping)
      (should-not tabulated-list-use-header-line)
      (should-not truncate-lines)
      (should visual-line-mode))))

(ert-deftest bitbucket-devops-pull-requests-ui-filters-by-state-branch-and-author ()
  (let* ((page
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-requests-page-1.json"))
         (pull-requests (alist-get 'values page)))
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--pull-requests pull-requests)
      (setq-local bitbucket-devops-pull-requests-ui--state-filter "OPEN")
      (should
       (equal
        (mapcar
         (lambda (pull-request) (alist-get 'id pull-request))
         (bitbucket-devops-pull-requests-ui--filtered-pull-requests))
        '(10)))
      (setq-local bitbucket-devops-pull-requests-ui--state-filter nil)
      (setq-local bitbucket-devops-pull-requests-ui--branch-filter "master")
      (should
       (equal
        (mapcar
         (lambda (pull-request) (alist-get 'id pull-request))
         (bitbucket-devops-pull-requests-ui--filtered-pull-requests))
        '(11)))
      (setq-local bitbucket-devops-pull-requests-ui--branch-filter nil)
      (setf (alist-get 'author (cadr pull-requests))
            '((display_name . "Other Author")))
      (setq-local bitbucket-devops-pull-requests-ui--author-filter "other author")
      (should
       (equal
        (mapcar
         (lambda (pull-request) (alist-get 'id pull-request))
         (bitbucket-devops-pull-requests-ui--filtered-pull-requests))
        '(10))))))

(ert-deftest bitbucket-devops-pull-requests-ui-state-filter-refreshes-server-page ()
  (let (refreshed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-ui-refresh)
                 (lambda () (setq refreshed t))))
        (bitbucket-devops-pull-requests-ui-set-state-filter "MERGED")
        (should (equal bitbucket-devops-pull-requests-ui--state-filter "MERGED"))
        (should refreshed)))))

(ert-deftest bitbucket-devops-pull-requests-ui-branch-filter-renders-locally ()
  (let (rendered)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-ui--render)
                 (lambda () (setq rendered t))))
        (bitbucket-devops-pull-requests-ui-set-branch-filter "main")
        (should (equal bitbucket-devops-pull-requests-ui--branch-filter "main"))
        (should rendered)
        (bitbucket-devops-pull-requests-ui-set-branch-filter "ALL")
        (should-not bitbucket-devops-pull-requests-ui--branch-filter)))))

(ert-deftest bitbucket-devops-pull-requests-ui-author-filter-renders-locally ()
  (let (rendered)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local
       bitbucket-devops-pull-requests-ui--pull-requests
       '(((author . ((display_name . "Ada"))))
         ((author . ((display_name . "Grace"))))))
      (should
       (equal (bitbucket-devops-pull-requests-ui--loaded-author-names)
              '("Ada" "Grace")))
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-ui--render)
                 (lambda () (setq rendered t))))
        (bitbucket-devops-pull-requests-ui-set-author-filter "Ada")
        (should (equal bitbucket-devops-pull-requests-ui--author-filter "Ada"))
        (should rendered)
        (bitbucket-devops-pull-requests-ui-set-author-filter "ALL")
        (should-not bitbucket-devops-pull-requests-ui--author-filter)))))

(ert-deftest bitbucket-devops-pull-requests-ui-branch-filter-offers-all ()
  (let (observed-collection observed-default)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--pull-requests
                  '(((source . ((branch . ((name . "feature")))))
                     (destination . ((branch . ((name . "main"))))))))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest arguments)
                   (setq observed-collection collection
                         observed-default (nth 4 arguments))
                   "ALL"))
                ((symbol-function 'bitbucket-devops-pull-requests-ui--branch-names)
                 #'ignore)
                ((symbol-function 'bitbucket-devops-pull-requests-ui--render)
                 #'ignore))
        (call-interactively #'bitbucket-devops-pull-requests-ui-set-branch-filter)))
    (should (equal observed-collection '("ALL" "feature" "main")))
    (should (equal observed-default "ALL"))))

(ert-deftest bitbucket-devops-pull-requests-ui-author-filter-offers-all ()
  (let (observed-collection observed-default)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--pull-requests
                  '(((author . ((display_name . "Ada"))))
                    ((author . ((display_name . "Grace"))))))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest arguments)
                   (setq observed-collection collection
                         observed-default (nth 4 arguments))
                   "ALL"))
                ((symbol-function 'bitbucket-devops-pull-requests-ui--render)
                 #'ignore))
        (call-interactively #'bitbucket-devops-pull-requests-ui-set-author-filter)))
    (should (equal observed-collection '("ALL" "Ada" "Grace")))
    (should (equal observed-default "ALL"))))

(ert-deftest bitbucket-devops-pull-requests-ui-receive-page-renders-entries ()
  (let ((page
         (bitbucket-devops-pull-requests-ui-test-read-json-fixture
          "pull-requests-page-1.json")))
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (bitbucket-devops-pull-requests-ui--receive-page page nil t)
      (should (= (length bitbucket-devops-pull-requests-ui--pull-requests) 2))
      (should (equal (mapcar #'car tabulated-list-entries) '("11" "10"))))))

(ert-deftest bitbucket-devops-pull-requests-ui-collect-statuses-follows-pagination ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        (next-url "https://api.bitbucket.org/2.0/statuses?page=2")
        requests
        result)
    (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-list-statuses)
               (lambda (_context _pull-request-id callback &optional requested-url)
                 (push requested-url requests)
                 (if requested-url
                     (funcall callback
                              '((values . (((state . "FAILED")))))
                              nil)
                   (funcall callback
                            `((values . (((state . "SUCCESSFUL"))))
                              (next . ,next-url))
                            nil)))))
      (bitbucket-devops-pull-requests-ui--collect-statuses
       context 11 (lambda (statuses error) (setq result (list statuses error))))
      (should (equal (reverse requests) (list nil next-url)))
      (should
       (equal
        result
        '((((state . "SUCCESSFUL")) ((state . "FAILED"))) nil))))))

(ert-deftest bitbucket-devops-pull-requests-ui-enrich-builds-updates-loaded-row ()
  (let* ((context '(:workspace "williseed1" :repo-slug "test"))
         (page
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-requests-page-1.json"))
         (pull-request (car (alist-get 'values page)))
         cached)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--pull-requests (list pull-request))
      (setq-local bitbucket-devops-pull-requests-ui--request-generation 3)
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-ui--collect-statuses)
                 (lambda (_context _pull-request-id callback &rest _)
                   (funcall callback
                            '(((state . "SUCCESSFUL"))
                              ((state . "FAILED")))
                            nil)))
                ((symbol-function 'bitbucket-devops-cache-merge-pull-requests)
                 (lambda (_context pull-requests)
                   (setq cached pull-requests)
                   bitbucket-devops-pull-requests-ui--pull-requests)))
        (bitbucket-devops-pull-requests-ui--enrich-builds context (list pull-request) 3)
        (should
         (equal
          (alist-get
           'bitbucket-devops-pull-requests-build-label
           (car bitbucket-devops-pull-requests-ui--pull-requests))
          "1 failed"))
        (should (equal cached bitbucket-devops-pull-requests-ui--pull-requests))))))

(ert-deftest bitbucket-devops-pull-requests-ui-refreshes-configured-newest-details ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        (bitbucket-devops-cache-enabled nil)
        (bitbucket-devops-pull-requests-sync-always-count 1)
        (bitbucket-devops-pull-requests-sync-active-count 3)
        requested)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--request-generation 4)
      (setq-local
       bitbucket-devops-pull-requests-ui--pull-requests
       '(((id . 1)
          (state . "DECLINED")
          (updated_on . "2026-06-07T12:00:00Z")
          (bitbucket-devops-pull-requests-build-label . "1 passed"))
         ((id . 2)
          (state . "OPEN")
          (updated_on . "2026-06-07T11:00:00Z"))
         ((id . 3)
          (state . "MERGED")
          (updated_on . "2026-06-07T10:00:00Z"))
         ((id . 4)
          (state . "OPEN")
          (updated_on . "2026-06-07T09:00:00Z"))))
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-get)
                 (lambda (_context id callback)
                   (push id requested)
                   (funcall
                    callback
                    `((id . ,id)
                      (state . ,(if (= id 1) "MERGED" "OPEN"))
                      (updated_on . "2026-06-07T13:00:00Z"))
                    nil))))
        (bitbucket-devops-pull-requests-ui--refresh-newest-loaded-details context 4)
        (should (equal (sort requested #'<) '(1 2)))
        (should
         (equal
          (alist-get 'state
                     (bitbucket-devops-pull-requests-ui--find-loaded 1))
          "MERGED"))
        (should
         (equal
          (alist-get
           'bitbucket-devops-pull-requests-build-label
           (bitbucket-devops-pull-requests-ui--find-loaded 1))
          "1 passed"))
        (should
         (equal
          (alist-get 'state
                     (bitbucket-devops-pull-requests-ui--find-loaded 3))
          "MERGED"))))))

(ert-deftest bitbucket-devops-pull-requests-ui-refresh-newest-details-can-be-disabled ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        (bitbucket-devops-pull-requests-sync-always-count 0)
        (bitbucket-devops-pull-requests-sync-active-count 0)
        requested)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--request-generation 2)
      (setq-local
       bitbucket-devops-pull-requests-ui--pull-requests
       '(((id . 1) (updated_on . "2026-06-07T12:00:00Z"))))
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-get)
                 (lambda (&rest _)
                   (setq requested t))))
        (bitbucket-devops-pull-requests-ui--refresh-newest-loaded-details context 2)
        (should-not requested)))))

(ert-deftest bitbucket-devops-pull-requests-ui-refresh-requests-first-page ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed
        callback)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-list)
                 (lambda (request-context request-callback &optional next-url state)
                   (setq observed (list request-context next-url state)
                         callback request-callback)
                   'request-process)))
        (should (eq (bitbucket-devops-pull-requests-ui-refresh) 'request-process))
        (should (equal observed (list context nil nil)))
        (should (functionp callback))))))

(ert-deftest bitbucket-devops-pull-requests-ui-load-more-requests-next-page ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        (next-url
         "https://api.bitbucket.org/2.0/repositories/williseed1/test/pullrequests?page=2")
        observed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--next-url next-url)
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-list)
                 (lambda (request-context _callback &optional request-next-url state)
                   (setq observed (list request-context request-next-url state))
                   'request-process)))
        (should (eq (bitbucket-devops-pull-requests-ui-load-more) 'request-process))
        (should (equal observed (list context next-url nil)))))))

(ert-deftest bitbucket-devops-pull-requests-ui-detail-renders-loaded-sections ()
  (let* ((pull-request
          (copy-tree
           (car
            (alist-get
             'values
             (bitbucket-devops-pull-requests-ui-test-read-json-fixture
              "pull-requests-page-1.json")))))
         (_description
          (setf (alist-get 'description pull-request)
                '((raw . "Migrate development config."))))
         (statuses
          (alist-get
           'values
           (bitbucket-devops-pull-requests-ui-test-read-json-fixture
            "pull-request-statuses.json")))
         (tasks
          (alist-get
           'values
           (bitbucket-devops-pull-requests-ui-test-read-json-fixture
            "pull-request-tasks.json")))
         (comments
          (alist-get
           'values
           (bitbucket-devops-pull-requests-ui-test-read-json-fixture
            "pull-request-comments.json")))
         (activity
          (alist-get
           'values
           (bitbucket-devops-pull-requests-ui-test-read-json-fixture
            "pull-request-activity.json")))
         (commits
          (alist-get
           'values
           (bitbucket-devops-pull-requests-ui-test-read-json-fixture
            "pull-request-commits.json")))
         (diffstat
          (alist-get
           'values
           (bitbucket-devops-pull-requests-ui-test-read-json-fixture
            "pull-request-diffstat.json"))))
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                  pull-request)
      (setq-local bitbucket-devops-pull-requests-ui--details-statuses statuses)
      (setq-local bitbucket-devops-pull-requests-ui--details-tasks tasks)
      (setq-local bitbucket-devops-pull-requests-ui--details-comments comments)
      (setq-local bitbucket-devops-pull-requests-ui--details-activity activity)
      (setq-local bitbucket-devops-pull-requests-ui--details-commits commits)
      (setq-local bitbucket-devops-pull-requests-ui--details-diffstat diffstat)
      (bitbucket-devops-pull-requests-ui--render-details)
      (let ((text (buffer-string)))
        (should (string-match-p "#11 Development" text))
        (should (string-match-p "development -> master" text))
        (should (string-match-p "Ada Reviewer, Grace Reviewer" text))
        (should (string-match-p "Ada Reviewer" text))
        (should (string-match-p "4 total, 2 passed, 1 failed, 1 in progress" text))
        (should (string-match-p "\\[SUCCESSFUL\\] Lint - No lint errors" text))
        (should (string-match-p "\\[FAILED\\] Pipeline - Unit tests failed" text))
        (should (string-match-p "3 total, 1 resolved, 2 unresolved" text))
        (should (string-match-p (regexp-quote "- [resolved] Update documentation") text))
        (should (string-match-p (regexp-quote "- [open] Fix lint") text))
        (should (string-match-p "1 comments, 1 replies, 1 deleted" text))
        (should (string-match-p "Ada Reviewer \\[resolved\\]" text))
        (should (string-match-p "Will Bosch: Yes, it points" text))
        (should (string-match-p "83bd24f12345 Merged in development" text))
        (should (string-match-p (regexp-quote "4 files, +72 -19") text))
        (should (string-match-p
                 (regexp-quote "config.org modified +63 -14")
                 text))))))

(ert-deftest bitbucket-devops-pull-requests-ui-refresh-details-requests-sections ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-get)
                 (lambda (request-context pull-request-id callback)
                   (push (list 'get request-context pull-request-id) observed)
                   (funcall callback '((id . 11) (title . "Development")) nil)))
                ((symbol-function 'bitbucket-devops-pull-requests-rest-list-activity)
                 (lambda (request-context pull-request-id callback &optional _next-url)
                   (push (list 'activity request-context pull-request-id) observed)
                   (funcall callback '((values . nil)) nil)))
                ((symbol-function 'bitbucket-devops-pull-requests-rest-list-comments)
                 (lambda (request-context pull-request-id callback &optional _next-url)
                   (push (list 'comments request-context pull-request-id) observed)
                   (funcall callback '((values . nil)) nil)))
                ((symbol-function 'bitbucket-devops-pull-requests-rest-list-commits)
                 (lambda (request-context pull-request-id callback &optional _next-url)
                   (push (list 'commits request-context pull-request-id) observed)
                   (funcall callback '((values . nil)) nil)))
                ((symbol-function 'bitbucket-devops-pull-requests-rest-list-statuses)
                 (lambda (request-context pull-request-id callback &optional _next-url)
                   (push (list 'statuses request-context pull-request-id) observed)
                   (funcall callback '((values . nil)) nil)))
                ((symbol-function 'bitbucket-devops-pull-requests-rest-list-tasks)
                 (lambda (request-context pull-request-id callback &optional _next-url)
                   (push (list 'tasks request-context pull-request-id) observed)
                   (funcall callback '((values . nil)) nil)))
                ((symbol-function 'bitbucket-devops-pull-requests-rest-list-diffstat)
                 (lambda (request-context pull-request-id callback &optional _next-url)
                   (push (list 'diffstat request-context pull-request-id) observed)
                   (funcall callback '((values . nil)) nil))))
        (bitbucket-devops-pull-requests-ui-refresh-details)
        (should
         (equal
          (mapcar #'car (reverse observed))
          '(get activity comments commits statuses tasks diffstat)))))))

(ert-deftest bitbucket-devops-pull-requests-ui-open-at-point-opens-loaded-pr ()
  (let* ((context '(:workspace "williseed1" :repo-slug "test"))
         (page
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-requests-page-1.json"))
         observed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (bitbucket-devops-pull-requests-ui--receive-page page nil t)
      (goto-char (point-min))
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-ui-show-details)
                 (lambda (request-context pull-request)
                   (setq observed
                         (list request-context (alist-get 'id pull-request))))))
        (bitbucket-devops-pull-requests-ui-open-at-point)
        (should (equal observed (list context 11)))))))

(ert-deftest bitbucket-devops-pull-requests-ui-browse-opens-list-or-selected-pr ()
  (let* ((context '(:workspace "williseed1" :repo-slug "test"))
         (page
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-requests-page-1.json"))
         opened)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (bitbucket-devops-pull-requests-ui--receive-page page nil t)
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _args) (push url opened))))
        (goto-char (point-min))
        (bitbucket-devops-pull-requests-ui-browse)
        (search-forward "Development")
        (bitbucket-devops-pull-requests-ui-browse)))
    (should
     (equal
      (reverse opened)
      '("https://bitbucket.org/williseed1/test/pull-requests/"
        "https://bitbucket.org/williseed1/test/pull-requests/11")))))

(ert-deftest bitbucket-devops-pull-requests-ui-browse-prefers-api-html-link ()
  (let ((opened nil))
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local
       bitbucket-devops-pull-requests-ui--details-pull-request
       '((id . 11)
         (links . ((html . ((href . "https://bitbucket.test/pr/11")))))))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _args) (setq opened url))))
        (bitbucket-devops-pull-requests-ui-browse)))
    (should (equal opened "https://bitbucket.test/pr/11"))))

(ert-deftest bitbucket-devops-pull-requests-ui-shift-enter-copies-list-link ()
  (let* ((context '(:workspace "williseed1" :repo-slug "test"))
         (page
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-requests-page-1.json"))
         copied)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (bitbucket-devops-pull-requests-ui--receive-page page nil t)
      (goto-char (point-min))
      (search-forward "11")
      (beginning-of-line)
      (cl-letf (((symbol-function 'kill-new)
                 (lambda (text &rest _arguments) (setq copied text))))
        (bitbucket-devops-pull-requests-ui-copy-browser-url-at-point)
        (end-of-line)
        (bitbucket-devops-pull-requests-ui-copy-browser-url-at-point))
      (should
       (equal copied
              "https://bitbucket.org/williseed1/test/pull-requests/11")))))

(ert-deftest bitbucket-devops-pull-requests-ui-shift-enter-copies-detail-links ()
  (let* ((context '(:workspace "williseed1" :repo-slug "test"))
         (pull-request
          (copy-tree
           (car
            (alist-get
             'values
             (bitbucket-devops-pull-requests-ui-test-read-json-fixture
              "pull-requests-page-1.json")))))
         (statuses
          (alist-get
           'values
           (bitbucket-devops-pull-requests-ui-test-read-json-fixture
            "pull-request-statuses.json")))
         copied)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                  pull-request)
      (setq-local bitbucket-devops-pull-requests-ui--details-statuses statuses)
      (bitbucket-devops-pull-requests-ui--render-details)
      (cl-letf (((symbol-function 'kill-new)
                 (lambda (text &rest _arguments) (push text copied))))
        (goto-char (point-min))
        (bitbucket-devops-pull-requests-ui-copy-browser-url-at-point)
        (search-forward "Pipeline - Unit tests failed")
        (end-of-line)
        (bitbucket-devops-pull-requests-ui-copy-browser-url-at-point))
      (should
       (equal copied
              '("https://ci.example.test/pipeline/11"
                "https://bitbucket.org/williseed1/test/pull-requests/11")))
      (goto-char (point-min))
      (search-forward "Description")
      (should-error
       (bitbucket-devops-pull-requests-ui-copy-browser-url-at-point)
       :type 'user-error))))

(ert-deftest bitbucket-devops-pull-requests-ui-detail-enter-opens-action-at-point ()
  (let* ((pull-request
          (copy-tree
           (car
            (alist-get
             'values
             (bitbucket-devops-pull-requests-ui-test-read-json-fixture
              "pull-requests-page-1.json")))))
         (opened nil))
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                  pull-request)
      (bitbucket-devops-pull-requests-ui--render-details)
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _args) (setq opened url))))
        (goto-char (point-min))
        (bitbucket-devops-pull-requests-ui-open-detail-at-point))
      (should
       (equal opened
              "https://bitbucket.org/williseed1/test/pull-requests/11")))))

(ert-deftest bitbucket-devops-pull-requests-ui-detail-title-edits-number-browses ()
  (let* ((context '(:workspace "williseed1" :repo-slug "test"))
         (pull-request
          (copy-tree
           (car
            (alist-get
             'values
             (bitbucket-devops-pull-requests-ui-test-read-json-fixture
              "pull-requests-page-1.json")))))
         updated
         opened)
    (setf (alist-get 'description pull-request) "Body")
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                  pull-request)
      (bitbucket-devops-pull-requests-ui--render-details)
      (cl-letf
          (((symbol-function 'read-string)
            (lambda (prompt initial-input &rest _arguments)
              (should (equal prompt "Pull request title: "))
              (should (equal initial-input "Development"))
              "New title"))
           ((symbol-function 'bitbucket-devops-pull-requests-rest-update)
            (lambda (request-context pull-request-id body _callback)
              (setq updated (list request-context pull-request-id body))))
           ((symbol-function 'browse-url)
            (lambda (url &rest _args) (setq opened url))))
        (goto-char (point-min))
        (search-forward "Development")
        (bitbucket-devops-pull-requests-ui-open-detail-at-point)
        (goto-char (point-min))
        (bitbucket-devops-pull-requests-ui-open-detail-at-point)))
    (should
     (equal
      updated
      (list
       context
       11
       '((title . "New title")
         (description . "Body")
         (draft . :false)))))
    (should
     (equal opened "https://bitbucket.org/williseed1/test/pull-requests/11"))))

(ert-deftest bitbucket-devops-pull-requests-ui-detail-enter-runs-line-actions ()
  (let* ((pull-request
          (copy-tree
           (car
            (alist-get
             'values
             (bitbucket-devops-pull-requests-ui-test-read-json-fixture
              "pull-requests-page-1.json")))))
         actions)
    (setf (alist-get 'description pull-request) "Editable body")
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                  pull-request)
      (bitbucket-devops-pull-requests-ui--render-details)
      (cl-letf
          (((symbol-function 'bitbucket-devops-pull-requests-ui-edit-description)
            (lambda () (interactive) (push 'description actions)))
           ((symbol-function 'bitbucket-devops-pull-requests-ui-change-state)
            (lambda () (interactive) (push 'state actions)))
           ((symbol-function 'bitbucket-devops-pull-requests-ui-toggle-draft)
            (lambda () (interactive) (push 'readiness actions)))
           ((symbol-function
             'bitbucket-devops-pull-requests-ui-checkout-source-branch)
            (lambda () (interactive) (push 'branch actions)))
           ((symbol-function 'bitbucket-devops-pull-requests-ui-add-reviewer)
            (lambda (&optional _identifier)
              (interactive)
              (push 'reviewer actions))))
        (goto-char (point-min))
        (search-forward (alist-get 'state pull-request))
        (bitbucket-devops-pull-requests-ui-open-detail-at-point)
        (goto-char (point-min))
        (search-forward "State:")
        (beginning-of-line)
        (bitbucket-devops-pull-requests-ui-open-detail-at-point)
        (goto-char (point-min))
        (search-forward "Description")
        (beginning-of-line)
        (bitbucket-devops-pull-requests-ui-open-detail-at-point)
        (search-forward "Editable body")
        (end-of-line)
        (bitbucket-devops-pull-requests-ui-open-detail-at-point)
        (goto-char (point-min))
        (search-forward "Readiness:")
        (beginning-of-line)
        (bitbucket-devops-pull-requests-ui-open-detail-at-point)
        (goto-char (point-min))
        (search-forward "Branches:")
        (end-of-line)
        (bitbucket-devops-pull-requests-ui-open-detail-at-point)
        (goto-char (point-min))
        (search-forward "\nReviewers\n")
        (beginning-of-line)
        (bitbucket-devops-pull-requests-ui-open-detail-at-point)
        (goto-char (point-min))
        (search-forward "Reviewers:")
        (end-of-line)
        (bitbucket-devops-pull-requests-ui-open-detail-at-point)))
    (should
     (equal actions
            '(reviewer reviewer branch readiness description description
                       state state)))))

(ert-deftest bitbucket-devops-pull-requests-ui-detail-enter-edits-comment-at-point ()
  (let* ((context '(:workspace "williseed1" :repo-slug "test"))
         (pull-request
          (car
           (alist-get
            'values
            (bitbucket-devops-pull-requests-ui-test-read-json-fixture
             "pull-requests-page-1.json"))))
         (comments
          (alist-get
           'values
           (bitbucket-devops-pull-requests-ui-test-read-json-fixture
            "pull-request-comments.json")))
         observed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                  pull-request)
      (setq-local bitbucket-devops-pull-requests-ui--details-comments comments)
      (bitbucket-devops-pull-requests-ui--render-details)
      (goto-char (point-min))
      (search-forward "#101")
      (beginning-of-line)
      (cl-letf
          (((symbol-function 'read-string)
            (lambda (prompt initial-input &rest _arguments)
              (should (equal prompt "Updated comment: "))
              (should (equal initial-input
                             "Can you explain this config change?"))
              "Updated at point"))
           ((symbol-function 'bitbucket-devops-pull-requests-rest-update-comment)
            (lambda (request-context pull-request-id comment-id text _callback)
              (setq observed
                    (list request-context pull-request-id comment-id text)))))
        (bitbucket-devops-pull-requests-ui-open-detail-at-point)))
    (should (equal observed (list context 11 101 "Updated at point")))))

(ert-deftest bitbucket-devops-pull-requests-ui-detail-enter-opens-build-status-url ()
  (let* ((pull-request
          (copy-tree
           (car
            (alist-get
             'values
             (bitbucket-devops-pull-requests-ui-test-read-json-fixture
              "pull-requests-page-1.json")))))
         (statuses
          (alist-get
           'values
           (bitbucket-devops-pull-requests-ui-test-read-json-fixture
            "pull-request-statuses.json")))
         opened)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                  pull-request)
      (setq-local bitbucket-devops-pull-requests-ui--details-statuses statuses)
      (bitbucket-devops-pull-requests-ui--render-details)
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _args) (setq opened url))))
        (goto-char (point-min))
        (search-forward "Pipeline - Unit tests failed")
        (bitbucket-devops-pull-requests-ui-open-detail-at-point)))
    (should (equal opened "https://ci.example.test/pipeline/11"))))

(ert-deftest bitbucket-devops-pull-requests-ui-detail-enter-can-open-status-locally ()
  (let* ((context '(:workspace "williseed1" :repo-slug "test"))
         (pull-request
          (copy-tree
           (car
            (alist-get
             'values
             (bitbucket-devops-pull-requests-ui-test-read-json-fixture
              "pull-requests-page-1.json")))))
         (statuses
          (copy-tree
           (alist-get
            'values
            (bitbucket-devops-pull-requests-ui-test-read-json-fixture
             "pull-request-statuses.json"))))
         opened)
    (setf (alist-get 'url (nth 2 statuses))
          "https://bitbucket.org/williseed1/test/pipelines/results/12")
    (let ((bitbucket-devops-pull-requests-build-status-action 'browser))
      (with-temp-buffer
        (bitbucket-devops-pull-requests-detail-mode)
        (setq-local bitbucket-devops-pull-requests-ui--context context)
        (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                    pull-request)
        (setq-local bitbucket-devops-pull-requests-ui--details-statuses statuses)
        (bitbucket-devops-pull-requests-ui--render-details)
        (cl-letf (((symbol-function 'bitbucket-devops-cache-pipelines)
                   (lambda (_context)
                     '(((uuid . "{pipeline-uuid}") (build_number . 12)))))
                  ((symbol-function 'bitbucket-devops-pipelines-details)
                   (lambda (request-context pipeline-uuid)
                     (setq opened (list request-context pipeline-uuid)))))
          (goto-char (point-min))
          (search-forward "Pipeline - Unit tests failed")
          (bitbucket-devops-pull-requests-ui-open-detail-at-point '(4)))))
    (should (equal opened (list context "{pipeline-uuid}")))))

(ert-deftest bitbucket-devops-pull-requests-ui-build-status-local-opens-locally ()
  (let ((bitbucket-devops-pull-requests-build-status-action 'local)
        opened)
    (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-ui-open-status-pipeline)
               (lambda () (setq opened 'local)))
              ((symbol-function 'bitbucket-devops-pull-requests-ui-browse-status)
               (lambda () (setq opened 'browser))))
      (bitbucket-devops-pull-requests-ui-open-status)
      (should (eq opened 'local))
      (bitbucket-devops-pull-requests-ui-open-status '(4))
      (should (eq opened 'browser)))))

(ert-deftest bitbucket-devops-pull-requests-ui-detail-sections-open-subviews ()
  (let* ((pull-request
          (copy-tree
           (car
            (alist-get
             'values
             (bitbucket-devops-pull-requests-ui-test-read-json-fixture
              "pull-requests-page-1.json")))))
         (activity
          (alist-get
           'values
           (bitbucket-devops-pull-requests-ui-test-read-json-fixture
            "pull-request-activity.json")))
         (commits
          (alist-get
           'values
           (bitbucket-devops-pull-requests-ui-test-read-json-fixture
            "pull-request-commits.json")))
         (diffstat
          (alist-get
           'values
           (bitbucket-devops-pull-requests-ui-test-read-json-fixture
            "pull-request-diffstat.json")))
         opened)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                  pull-request)
      (setq-local bitbucket-devops-pull-requests-ui--details-activity activity)
      (setq-local bitbucket-devops-pull-requests-ui--details-commits commits)
      (setq-local bitbucket-devops-pull-requests-ui--details-diffstat diffstat)
      (bitbucket-devops-pull-requests-ui--render-details)
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-ui-open-commits)
                 (lambda () (interactive) (push 'commits opened)))
                ((symbol-function 'bitbucket-devops-pull-requests-ui-open-activity)
                 (lambda () (interactive) (push 'activity opened)))
                ((symbol-function 'bitbucket-devops-pull-requests-ui-open-diff)
                 (lambda (&optional _viewer)
                   (interactive)
                   (push 'diff opened))))
        (goto-char (point-min))
        (search-forward "Can you explain this config change?")
        (bitbucket-devops-pull-requests-ui-open-detail-at-point)
        (search-forward "point to new location")
        (bitbucket-devops-pull-requests-ui-open-detail-at-point)
        (search-forward "config.org modified")
        (bitbucket-devops-pull-requests-ui-open-detail-at-point)))
    (should (equal opened '(diff commits activity)))))

(ert-deftest bitbucket-devops-pull-requests-ui-checkout-switches-existing-local-branch ()
  (let ((context
         '(:root "/repo/"
           :remote "origin"
           :workspace "williseed1"
           :repo-slug "test"))
        calls)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local
       bitbucket-devops-pull-requests-ui--details-pull-request
       '((source . ((branch . ((name . "feature/example")))))))
      (cl-letf
          (((symbol-function 'bitbucket-devops-pull-requests-ui--git-call)
            (lambda (_context &rest arguments)
              (push arguments calls)
              ""))
           ((symbol-function 'bitbucket-devops-pull-requests-ui--git-ref-exists-p)
            (lambda (_context ref)
              (equal ref "refs/heads/feature/example"))))
        (bitbucket-devops-pull-requests-ui-checkout-source-branch)
        (should
         (equal
          (reverse calls)
          '(("check-ref-format" "--branch" "feature/example")
            ("check-ref-format" "refs/remotes/origin/feature/example")
            ("fetch" "--no-tags" "origin"
             "+refs/heads/feature/example:refs/remotes/origin/feature/example")
            ("switch" "--" "feature/example"))))
        (should
         (equal
          (plist-get bitbucket-devops-pull-requests-ui--context :branch)
          "feature/example"))))))

(ert-deftest bitbucket-devops-pull-requests-ui-checkout-creates-tracking-branch ()
  (let ((context
         '(:root "/repo/"
           :remote "upstream"
           :workspace "williseed1"
           :repo-slug "test"))
        calls)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local
       bitbucket-devops-pull-requests-ui--details-pull-request
       '((source . ((branch . ((name . "review/fix")))))))
      (cl-letf
          (((symbol-function 'bitbucket-devops-pull-requests-ui--git-call)
            (lambda (_context &rest arguments)
              (push arguments calls)
              ""))
           ((symbol-function 'bitbucket-devops-pull-requests-ui--git-ref-exists-p)
            (lambda (&rest _) nil)))
        (bitbucket-devops-pull-requests-ui-checkout-source-branch)
        (should
         (equal
          (reverse calls)
          '(("check-ref-format" "--branch" "review/fix")
            ("check-ref-format" "refs/remotes/upstream/review/fix")
            ("fetch" "--no-tags" "upstream"
             "+refs/heads/review/fix:refs/remotes/upstream/review/fix")
            ("switch" "--track" "-c" "review/fix"
             "refs/remotes/upstream/review/fix"))))))))

(ert-deftest bitbucket-devops-pull-requests-ui-open-diff-renders-diff-buffer ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        (diff-text
         (bitbucket-devops-pull-requests-ui-test-read-text-fixture
          "pull-request-diff.diff"))
        displayed-previous)
    (unwind-protect
        (with-temp-buffer
          (bitbucket-devops-pull-requests-detail-mode)
          (let ((details-buffer (current-buffer)))
          (setq-local bitbucket-devops-pull-requests-ui--context context)
          (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
          (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                      '((id . 11)))
          (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-get-diff)
                     (lambda (request-context pull-request-id callback)
                       (should (equal request-context context))
                       (should (= pull-request-id 11))
                       (with-temp-buffer
                         (funcall callback diff-text nil))))
                    ((symbol-function 'bitbucket-devops-ui--display-buffer)
                     (lambda (buffer _select previous-buffer)
                       (setq displayed-previous previous-buffer)
                       buffer)))
            (bitbucket-devops-pull-requests-ui-open-diff))
          (should (eq displayed-previous details-buffer))
          (with-current-buffer
              (get-buffer
               "*Bitbucket Pull Request Diff: williseed1/test#11*")
            (should (derived-mode-p 'diff-mode))
            (should (equal bitbucket-devops-pull-requests-ui--context context))
            (should (= bitbucket-devops-pull-requests-ui--details-pull-request-id 11))
            (should
             (string-match-p
              "PR #11"
              (apply #'concat header-line-format)))
            (should
             (string-match-p
              "1 file"
              (apply #'concat header-line-format)))
            (should (string-match-p "Use the dedicated Bitbucket test repository"
                                    (buffer-string))))))
      (when-let ((buffer
                  (get-buffer
                   "*Bitbucket Pull Request Diff: williseed1/test#11*")))
        (kill-buffer buffer)))))

(ert-deftest bitbucket-devops-pull-requests-ui-fetches-fork-pr-source-revision ()
  (let ((context '(:root "/tmp/repository/"
                   :remote "origin"
                   :workspace "destination"
                   :repo-slug "repo"))
        (pull-request
         '((id . 11)
           (source
            . ((branch . ((name . "feature/example")))
               (commit . ((hash . "abcdef123456")))
               (repository . ((full_name . "contributor/fork")))))))
        calls)
    (cl-letf
        (((symbol-function 'bitbucket-devops-pull-requests-ui--git-call)
          (lambda (_context &rest arguments)
            (push arguments calls)
            ""))
         ((symbol-function
           'bitbucket-devops-pull-requests-ui--git-commit-exists-p)
          (lambda (_context hash) (equal hash "abcdef123456"))))
      (should
       (equal
        (bitbucket-devops-pull-requests-ui--fetch-pull-request-side
         context pull-request 'source)
        "abcdef123456")))
    (should
     (equal
      (nreverse calls)
      '(("check-ref-format" "--branch" "feature/example")
        ("check-ref-format" "refs/bitbucket-devops-pull-requests/11/source")
        ("fetch" "--no-tags" "git@bitbucket.org:contributor/fork.git"
         "+refs/heads/feature/example:refs/bitbucket-devops-pull-requests/11/source"))))))

(ert-deftest bitbucket-devops-pull-requests-ui-opens-pr-range-in-magit ()
  (let ((context '(:root "/tmp/repository/"
                   :workspace "williseed1"
                   :repo-slug "test"))
        (pull-request
         '((id . 11)
           (source . ((commit . ((hash . "source123")))))
           (destination . ((commit . ((hash . "destination123")))))))
        observed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request pull-request)
      (cl-letf
          (((symbol-function
             'bitbucket-devops-pull-requests-ui--ensure-pull-request-revisions)
            (lambda (request-context request-pull-request)
              (should (equal request-context context))
              (should (equal request-pull-request pull-request))
              '("destination123" "source123")))
           ((symbol-function 'magit-diff-range)
            (lambda (range &rest _arguments)
              (setq observed (list range default-directory)))))
        (bitbucket-devops-pull-requests-ui-open-diff 'magit))
      (should
       (equal observed
              '("destination123...source123" "/tmp/repository/"))))))

(ert-deftest bitbucket-devops-pull-requests-ui-ediff-compares-renamed-file ()
  (let ((context '(:root "/tmp/repository/"
                   :workspace "williseed1"
                   :repo-slug "test"))
        (pull-request '((id . 11)))
        (entry
         '((status . "renamed")
           (old . ((path . "old-name.txt")))
           (new . ((path . "new-name.txt")))))
        observed
        created-buffers)
    (unwind-protect
        (with-temp-buffer
          (bitbucket-devops-pull-requests-detail-mode)
          (setq-local bitbucket-devops-pull-requests-ui--context context)
          (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
          (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                      pull-request)
          (setq-local bitbucket-devops-pull-requests-ui--details-diffstat
                      (list entry))
          (cl-letf
              (((symbol-function
                 'bitbucket-devops-pull-requests-ui--ensure-pull-request-revisions)
                (lambda (&rest _arguments)
                  '("destination123" "source123")))
               ((symbol-function 'bitbucket-devops-pull-requests-ui--git-call)
                (lambda (_context &rest arguments)
                  (should (equal arguments
                                 '("merge-base"
                                   "destination123"
                                   "source123")))
                  "mergebase123"))
               ((symbol-function 'bitbucket-devops-pull-requests-ui--git-call-raw)
                (lambda (_context &rest arguments)
                  (pcase arguments
                    (`("show" "mergebase123:old-name.txt") "before\n")
                    (`("show" "source123:new-name.txt") "after\n")
                    (_ (ert-fail (format "Unexpected Git call: %S"
                                         arguments))))))
               ((symbol-function 'completing-read)
                (lambda (&rest _arguments)
                  "1. renamed  old-name.txt -> new-name.txt"))
               ((symbol-function 'ediff-buffers)
                (lambda (before after &optional _hooks _job-name)
                  (setq created-buffers (list before after))
                  (setq observed
                        (list
                         (with-current-buffer before (buffer-string))
                         (with-current-buffer after (buffer-string)))))))
            (bitbucket-devops-pull-requests-ui-open-diff 'ediff)))
      (mapc
       (lambda (buffer)
         (when (buffer-live-p buffer)
           (kill-buffer buffer)))
       created-buffers))
    (should (equal observed '("before\n" "after\n")))))

(ert-deftest bitbucket-devops-pull-requests-ui-chooses-one-time-diff-viewer ()
  (let (observed)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _arguments) "Magit range diff"))
              ((symbol-function 'bitbucket-devops-pull-requests-ui-open-diff)
               (lambda (&optional viewer) (setq observed viewer))))
      (bitbucket-devops-pull-requests-ui-choose-diff-viewer))
    (should (eq observed 'magit))))

(ert-deftest bitbucket-devops-pull-requests-ui-diff-position-infers-inline-location ()
  (with-temp-buffer
    (insert
     "diff --git a/lib/example.el b/lib/example.el\n"
     "--- a/lib/example.el\n"
     "+++ b/lib/example.el\n"
     "@@ -10,3 +10,3 @@\n"
     " context\n"
     "-old\n"
     "+new\n")
    (bitbucket-devops-pull-requests-diff-mode)
    (goto-char (point-min))
    (search-forward "+new")
    (should
     (equal
      (bitbucket-devops-pull-requests-ui--diff-position-at-point)
      '(:path "lib/example.el" :to 11)))
    (search-backward "-old")
    (should
     (equal
      (bitbucket-devops-pull-requests-ui--diff-position-at-point)
      '(:path "lib/example.el" :from 11)))))

(ert-deftest bitbucket-devops-pull-requests-ui-diff-position-supports-deleted-files ()
  (with-temp-buffer
    (insert
     "diff --git a/lib/obsolete.el b/lib/obsolete.el\n"
     "deleted file mode 100644\n"
     "--- a/lib/obsolete.el\n"
     "+++ /dev/null\n"
     "@@ -4,2 +0,0 @@\n"
     "-old line\n"
     "-another old line\n")
    (bitbucket-devops-pull-requests-diff-mode)
    (goto-char (point-min))
    (search-forward "-another old line")
    (should
     (equal
      (bitbucket-devops-pull-requests-ui--diff-position-at-point)
      '(:path "lib/obsolete.el" :from 5)))))

(ert-deftest bitbucket-devops-pull-requests-ui-diff-position-supports-renamed-files ()
  (with-temp-buffer
    (insert
     "diff --git a/lib/old-name.el b/lib/new-name.el\n"
     "similarity index 80%\n"
     "rename from lib/old-name.el\n"
     "rename to lib/new-name.el\n"
     "--- a/lib/old-name.el\n"
     "+++ b/lib/new-name.el\n"
     "@@ -8,2 +8,2 @@\n"
     "-old line\n"
     "+new line\n"
     " context\n")
    (bitbucket-devops-pull-requests-diff-mode)
    (goto-char (point-min))
    (search-forward "-old line")
    (should
     (equal
      (bitbucket-devops-pull-requests-ui--diff-position-at-point)
      '(:path "lib/old-name.el" :from 8)))
    (search-forward "+new line")
    (should
     (equal
      (bitbucket-devops-pull-requests-ui--diff-position-at-point)
      '(:path "lib/new-name.el" :to 8)))
    (search-forward " context")
    (should
     (equal
      (bitbucket-devops-pull-requests-ui--diff-position-at-point)
      '(:path "lib/new-name.el" :to 9)))))

(ert-deftest bitbucket-devops-pull-requests-ui-inline-comment-at-diff-point-only-reads-text ()
  (with-temp-buffer
    (insert
     "diff --git a/lib/example.el b/lib/example.el\n"
     "--- a/lib/example.el\n"
     "+++ b/lib/example.el\n"
     "@@ -10,2 +10,2 @@\n"
     "-old\n"
     "+new\n")
    (bitbucket-devops-pull-requests-diff-mode)
    (setq-local bitbucket-devops-pull-requests-ui--context
                '(:workspace "williseed1" :repo-slug "test"))
    (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
    (goto-char (point-min))
    (search-forward "+new")
    (cl-letf (((symbol-function 'read-string)
               (lambda (prompt &rest _arguments)
                 (should (equal prompt "Inline comment: "))
                 "Please check this"))
              ((symbol-function 'completing-read)
               (lambda (&rest _arguments)
                 (ert-fail "Location should be inferred from the diff")))
              ((symbol-function 'read-number)
               (lambda (&rest _arguments)
                 (ert-fail "Location should be inferred from the diff"))))
      (should
       (equal
        (bitbucket-devops-pull-requests-ui--read-inline-comment-arguments)
        '("Please check this" (:path "lib/example.el" :to 10)))))))

(ert-deftest bitbucket-devops-pull-requests-ui-deleted-and-renamed-inline-comments-only-read-text ()
  (dolist
      (case
       '(("diff --git a/obsolete.el b/obsolete.el\n\
deleted file mode 100644\n\
--- a/obsolete.el\n\
+++ /dev/null\n\
@@ -3 +0,0 @@\n\
-deleted line\n"
          "-deleted line"
          (:path "obsolete.el" :from 3))
         ("diff --git a/old.el b/new.el\n\
similarity index 75%\n\
rename from old.el\n\
rename to new.el\n\
--- a/old.el\n\
+++ b/new.el\n\
@@ -7 +7 @@\n\
-old name line\n\
+new name line\n"
          "+new name line"
          (:path "new.el" :to 7))))
    (pcase-let ((`(,diff ,target ,expected) case))
      (with-temp-buffer
        (insert diff)
        (bitbucket-devops-pull-requests-diff-mode)
        (setq-local bitbucket-devops-pull-requests-ui--context
                    '(:workspace "williseed1" :repo-slug "test"))
        (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
        (goto-char (point-min))
        (search-forward target)
        (cl-letf (((symbol-function 'read-string)
                   (lambda (prompt &rest _arguments)
                     (should (equal prompt "Inline comment: "))
                     "Review this"))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _arguments)
                     (ert-fail "Location should be inferred from the diff")))
                  ((symbol-function 'read-number)
                   (lambda (&rest _arguments)
                     (ert-fail "Location should be inferred from the diff"))))
          (should
           (equal
            (bitbucket-devops-pull-requests-ui--read-inline-comment-arguments)
            (list "Review this" expected))))))))

(ert-deftest bitbucket-devops-pull-requests-ui-inline-comment-file-metadata-uses-first-change ()
  (with-temp-buffer
    (insert
     "diff --git a/random.txt b/random.txt\n"
     "new file mode 100644\n"
     "index 0000000..eee297d\n"
     "--- /dev/null\n"
     "+++ b/random.txt\n"
     "@@ -0,0 +1,2 @@\n"
     "+hiello\n"
     "+sir\n")
    (bitbucket-devops-pull-requests-diff-mode)
    (setq-local bitbucket-devops-pull-requests-ui--context
                '(:workspace "williseed1" :repo-slug "test"))
    (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
    (goto-char (point-min))
    (search-forward "new file mode")
    (cl-letf (((symbol-function 'read-string)
               (lambda (prompt &rest _arguments)
                 (should (equal prompt "Inline comment: "))
                 "Review the new file"))
              ((symbol-function 'completing-read)
               (lambda (&rest _arguments)
                 (ert-fail "Location should be inferred from the file diff")))
              ((symbol-function 'read-number)
               (lambda (&rest _arguments)
                 (ert-fail "Location should be inferred from the file diff"))))
      (should
       (equal
        (bitbucket-devops-pull-requests-ui--read-inline-comment-arguments)
        '("Review the new file" (:path "random.txt" :to 1)))))))

(ert-deftest bitbucket-devops-pull-requests-ui-inline-comment-rejects-files-without-lines ()
  (dolist
      (diff
       '("diff --git a/newfile.txt b/anotherfile.txt\n\
similarity index 100%\n\
rename from newfile.txt\n\
rename to anotherfile.txt\n"
         "diff --git a/test.txt b/test.txt\n\
deleted file mode 100644\n\
index e69de29..0000000\n"))
    (with-temp-buffer
      (insert diff)
      (bitbucket-devops-pull-requests-diff-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (goto-char (point-min))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _arguments)
                   (ert-fail "A file without changed lines should not prompt")))
                ((symbol-function 'completing-read)
                 (lambda (&rest _arguments)
                   (ert-fail "A diff buffer should not use manual location prompts")))
                ((symbol-function 'read-number)
                 (lambda (&rest _arguments)
                   (ert-fail "A diff buffer should not use manual location prompts"))))
        (should-error
         (bitbucket-devops-pull-requests-ui--read-inline-comment-arguments)
         :type 'user-error)))))

(ert-deftest bitbucket-devops-pull-requests-ui-review-actions-call-rest-and-refresh ()
  (let ((context '(:workspace "williseed1" :repo-slug "test")))
    (dolist (case
             '((bitbucket-devops-pull-requests-ui-approve
                bitbucket-devops-pull-requests-rest-approve)
               (bitbucket-devops-pull-requests-ui-remove-approval
                bitbucket-devops-pull-requests-rest-remove-approval)
               (bitbucket-devops-pull-requests-ui-request-changes
                bitbucket-devops-pull-requests-rest-request-changes)
               (bitbucket-devops-pull-requests-ui-remove-request-changes
                bitbucket-devops-pull-requests-rest-remove-request-changes)))
      (let (observed refreshed)
        (with-temp-buffer
          (bitbucket-devops-pull-requests-detail-mode)
          (setq-local bitbucket-devops-pull-requests-ui--context context)
          (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
          (cl-letf (((symbol-function (nth 1 case))
                     (lambda (request-context pull-request-id callback)
                       (setq observed (list request-context pull-request-id))
                       (funcall callback nil nil)))
                    ((symbol-function 'bitbucket-devops-pull-requests-ui-refresh-details)
                     (lambda () (setq refreshed t))))
            (funcall (nth 0 case))
            (should (equal observed (list context 11)))
            (should refreshed)))))))

(ert-deftest bitbucket-devops-pull-requests-ui-review-action-error-does-not-refresh ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        refreshed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-approve)
                 (lambda (_context _pull-request-id callback)
                   (funcall callback nil '(:message "Missing scope"))))
                ((symbol-function 'bitbucket-devops-pull-requests-ui-refresh-details)
                 (lambda () (setq refreshed t))))
        (bitbucket-devops-pull-requests-ui-approve)
        (should-not refreshed)))))

(ert-deftest bitbucket-devops-pull-requests-ui-add-comment-posts-text-and-refreshes ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed
        refreshed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-create-comment)
                 (lambda (request-context pull-request-id text callback
                                          &optional parent-id)
                   (setq observed
                         (list request-context pull-request-id text parent-id))
                   (funcall callback '((id . 104)) nil)))
                ((symbol-function 'bitbucket-devops-pull-requests-ui-refresh-details)
                 (lambda () (setq refreshed t))))
        (bitbucket-devops-pull-requests-ui-add-comment "Looks good")
        (should (equal observed (list context 11 "Looks good" nil)))
        (should refreshed)))))

(ert-deftest bitbucket-devops-pull-requests-ui-add-inline-comment-posts-location ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed
        refreshed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-create-comment)
                 (lambda (request-context pull-request-id text callback
                                          &optional parent-id inline-location)
                   (setq observed
                         (list request-context
                               pull-request-id
                               text
                               parent-id
                               inline-location))
                   (funcall callback '((id . 105)) nil)))
                ((symbol-function 'bitbucket-devops-pull-requests-ui-refresh-details)
                 (lambda () (setq refreshed t))))
        (bitbucket-devops-pull-requests-ui-add-inline-comment
         "Please check this"
         '(:path "lib/example.el" :to 42))
        (should
         (equal observed
                (list context
                      11
                      "Please check this"
                      nil
                      '(:path "lib/example.el" :to 42))))
        (should refreshed)))))

(ert-deftest bitbucket-devops-pull-requests-ui-reply-posts-parent-comment-id ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        (comments
         (alist-get
          'values
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-request-comments.json")))
        observed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local bitbucket-devops-pull-requests-ui--details-comments comments)
      (let ((selection
             (caar (bitbucket-devops-pull-requests-ui--comment-candidates))))
        (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-create-comment)
                   (lambda (request-context pull-request-id text _callback
                                            &optional parent-id)
                     (setq observed
                           (list request-context pull-request-id text parent-id)))))
          (bitbucket-devops-pull-requests-ui-reply-to-comment selection "Reply text")
          (should (equal observed (list context 11 "Reply text" 101))))))))

(ert-deftest bitbucket-devops-pull-requests-ui-edits-loaded-comment-and-refreshes ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        (comments
         (alist-get
          'values
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-request-comments.json")))
        observed
        refreshed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local bitbucket-devops-pull-requests-ui--details-comments comments)
      (let ((selection
             (caar (bitbucket-devops-pull-requests-ui--comment-candidates))))
        (cl-letf
            (((symbol-function 'bitbucket-devops-pull-requests-rest-update-comment)
              (lambda (request-context pull-request-id comment-id text callback)
                (setq observed
                      (list request-context pull-request-id comment-id text))
                (funcall callback '((id . 101)) nil)))
             ((symbol-function 'bitbucket-devops-pull-requests-ui-refresh-details)
              (lambda () (setq refreshed t))))
          (bitbucket-devops-pull-requests-ui-edit-comment selection "Updated text")
          (should (equal observed (list context 11 101 "Updated text")))
          (should refreshed))))))

(ert-deftest bitbucket-devops-pull-requests-ui-deletes-comment-after-confirmation ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        (comments
         (alist-get
          'values
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-request-comments.json")))
        deleted)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local bitbucket-devops-pull-requests-ui--details-comments comments)
      (let ((selection
             (caar (bitbucket-devops-pull-requests-ui--comment-candidates))))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                  ((symbol-function 'bitbucket-devops-pull-requests-rest-delete-comment)
                   (lambda (&rest _) (setq deleted t))))
          (bitbucket-devops-pull-requests-ui-delete-comment selection)
          (should-not deleted))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                  ((symbol-function 'bitbucket-devops-pull-requests-rest-delete-comment)
                   (lambda (_context _pull-request-id comment-id _callback)
                     (setq deleted comment-id))))
          (bitbucket-devops-pull-requests-ui-delete-comment selection)
          (should (= deleted 101)))))))

(ert-deftest bitbucket-devops-pull-requests-ui-delete-comment-preserves-point ()
  (let* ((context '(:workspace "williseed1" :repo-slug "test"))
         (pull-request
          (copy-tree
           (car
            (alist-get
             'values
             (bitbucket-devops-pull-requests-ui-test-read-json-fixture
              "pull-requests-page-1.json")))))
         (comments
          (copy-tree
           (alist-get
            'values
            (bitbucket-devops-pull-requests-ui-test-read-json-fixture
             "pull-request-comments.json")))))
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                  pull-request)
      (setq-local bitbucket-devops-pull-requests-ui--details-comments comments)
      (bitbucket-devops-pull-requests-ui--render-details)
      (goto-char (point-min))
      (search-forward "#101")
      (let ((selection
             (caar (bitbucket-devops-pull-requests-ui--comment-candidates)))
            (column (current-column)))
        (cl-letf
            (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
             ((symbol-function 'bitbucket-devops-pull-requests-rest-delete-comment)
              (lambda (_context _pull-request-id comment-id callback)
                (setq bitbucket-devops-pull-requests-ui--details-comments
                      (seq-remove
                       (lambda (comment)
                         (= (or (alist-get 'id comment) -1) comment-id))
                       bitbucket-devops-pull-requests-ui--details-comments))
                (funcall callback nil nil)))
             ((symbol-function 'bitbucket-devops-pull-requests-ui-refresh-details)
              #'bitbucket-devops-pull-requests-ui--render-details))
          (bitbucket-devops-pull-requests-ui-delete-comment selection)
          (should (> (point) (point-min)))
          (should (= (current-column) column)))))))

(ert-deftest bitbucket-devops-pull-requests-ui-resolves-and-reopens-comment-threads ()
  (let* ((context '(:workspace "williseed1" :repo-slug "test"))
         (comments
          (alist-get
           'values
           (bitbucket-devops-pull-requests-ui-test-read-json-fixture
            "pull-request-comments.json")))
         (resolved-selection
          (caar
           (let ((bitbucket-devops-pull-requests-ui--details-comments comments))
             (bitbucket-devops-pull-requests-ui--comment-candidates
              #'bitbucket-devops-pull-requests-ui--resolved-thread-p))))
         (unresolved-comments (copy-tree comments))
         observed)
    (setf (alist-get 'resolution (car unresolved-comments)) nil)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local bitbucket-devops-pull-requests-ui--details-comments
                  unresolved-comments)
      (let ((selection
             (caar
              (bitbucket-devops-pull-requests-ui--comment-candidates
               #'bitbucket-devops-pull-requests-ui--unresolved-thread-p))))
        (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-resolve-comment)
                   (lambda (_context _pull-request-id comment-id _callback)
                     (setq observed (list 'resolve comment-id)))))
          (bitbucket-devops-pull-requests-ui-resolve-comment selection)
          (should (equal observed '(resolve 101)))))
      (setq-local bitbucket-devops-pull-requests-ui--details-comments comments)
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-reopen-comment)
                 (lambda (_context _pull-request-id comment-id _callback)
                   (setq observed (list 'reopen comment-id)))))
        (bitbucket-devops-pull-requests-ui-reopen-comment resolved-selection)
        (should (equal observed '(reopen 101)))))))

(ert-deftest bitbucket-devops-pull-requests-ui-creates-and-edits-tasks ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        (tasks
         (alist-get
          'values
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-request-tasks.json")))
        observed
        refreshed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local bitbucket-devops-pull-requests-ui--details-tasks tasks)
      (cl-letf
          (((symbol-function 'bitbucket-devops-pull-requests-rest-create-task)
            (lambda (request-context pull-request-id text callback)
              (setq observed (list 'create request-context pull-request-id text))
              (funcall callback '((id . 204)) nil)))
           ((symbol-function 'bitbucket-devops-pull-requests-ui-refresh-details)
            (lambda () (setq refreshed t))))
        (bitbucket-devops-pull-requests-ui-create-task "Review release notes")
        (should
         (equal observed (list 'create context 11 "Review release notes")))
        (should refreshed))
      (setq refreshed nil)
      (let ((selection (caar (bitbucket-devops-pull-requests-ui--task-candidates))))
        (cl-letf
            (((symbol-function 'bitbucket-devops-pull-requests-rest-update-task)
              (lambda (request-context pull-request-id task-id callback
                                       &optional text state)
                (setq observed
                      (list 'edit request-context pull-request-id task-id
                            text state))
                (funcall callback '((id . 201)) nil)))
             ((symbol-function 'bitbucket-devops-pull-requests-ui-refresh-details)
              (lambda () (setq refreshed t))))
          (bitbucket-devops-pull-requests-ui-edit-task selection "Updated docs")
          (should
           (equal observed (list 'edit context 11 201 "Updated docs" nil)))
          (should refreshed))))))

(ert-deftest bitbucket-devops-pull-requests-ui-deletes-tasks-after-confirmation ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        (tasks
         (alist-get
          'values
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-request-tasks.json")))
        deleted)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local bitbucket-devops-pull-requests-ui--details-tasks tasks)
      (let ((selection (caar (bitbucket-devops-pull-requests-ui--task-candidates))))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                  ((symbol-function 'bitbucket-devops-pull-requests-rest-delete-task)
                   (lambda (&rest _) (setq deleted t))))
          (bitbucket-devops-pull-requests-ui-delete-task selection)
          (should-not deleted))
        (cl-letf
            (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
             ((symbol-function 'bitbucket-devops-pull-requests-rest-delete-task)
              (lambda (_context _pull-request-id task-id _callback)
                (setq deleted task-id))))
          (bitbucket-devops-pull-requests-ui-delete-task selection)
          (should (= deleted 201)))))))

(ert-deftest bitbucket-devops-pull-requests-ui-resolves-and-reopens-tasks ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        (tasks
         (alist-get
          'values
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-request-tasks.json")))
        observed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local bitbucket-devops-pull-requests-ui--details-tasks tasks)
      (cl-letf
          (((symbol-function 'bitbucket-devops-pull-requests-rest-update-task)
            (lambda (_context _pull-request-id task-id _callback
                             &optional text state)
              (setq observed (list task-id text state)))))
        (let ((open-selection
               (caar
                (bitbucket-devops-pull-requests-ui--task-candidates
                 #'bitbucket-devops-pull-requests-ui--open-task-p))))
          (bitbucket-devops-pull-requests-ui-resolve-task open-selection)
          (should (equal observed '(202 nil "RESOLVED"))))
        (let ((resolved-selection
               (caar
                (bitbucket-devops-pull-requests-ui--task-candidates
                 #'bitbucket-devops-pull-requests-ui--resolved-task-p))))
          (bitbucket-devops-pull-requests-ui-reopen-task resolved-selection)
          (should (equal observed '(201 nil "UNRESOLVED"))))))))

(ert-deftest bitbucket-devops-pull-requests-ui-ret-toggles-task-at-point-in-place ()
  (let* ((context '(:workspace "williseed1" :repo-slug "test"))
         (page
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-requests-page-1.json"))
         (pull-request (car (alist-get 'values page)))
         (tasks
          (alist-get
           'values
           (bitbucket-devops-pull-requests-ui-test-read-json-fixture
            "pull-request-tasks.json")))
         states)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                  pull-request)
      (setq-local bitbucket-devops-pull-requests-ui--details-tasks tasks)
      (bitbucket-devops-pull-requests-ui--render-details)
      (goto-char (point-min))
      (search-forward "Fix lint")
      (let ((column (current-column)))
        (cl-letf
            (((symbol-function 'bitbucket-devops-pull-requests-rest-update-task)
              (lambda (_context _pull-request-id task-id callback
                       &optional _text state)
                (should (= task-id 202))
                (push state states)
                (setf (alist-get 'state
                                 (bitbucket-devops-pull-requests-ui--task-at-point))
                      state)
                (funcall callback '((id . 202)) nil)))
             ((symbol-function 'bitbucket-devops-pull-requests-ui-refresh-details)
              #'bitbucket-devops-pull-requests-ui--render-details))
          (bitbucket-devops-pull-requests-ui-open-detail-at-point)
          (should (equal (car states) "RESOLVED"))
          (should (= (current-column) column))
          (should (= (bitbucket-devops-pull-requests-ui--property-at-point-or-line
                      'bitbucket-devops-pull-requests-task-id)
                     202))
          (should (string-match-p "\\[resolved\\]" (thing-at-point 'line t)))
          (bitbucket-devops-pull-requests-ui-open-detail-at-point)
          (should (equal states '("UNRESOLVED" "RESOLVED")))
          (should (= (current-column) column))
          (should (= (bitbucket-devops-pull-requests-ui--property-at-point-or-line
                      'bitbucket-devops-pull-requests-task-id)
                     202))
          (should (string-match-p "\\[open\\]" (thing-at-point 'line t))))))))

(ert-deftest bitbucket-devops-pull-requests-ui-decline-requires-confirmation ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        called)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                  '((id . 11) (title . "Development")))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _args) nil))
                ((symbol-function 'bitbucket-devops-pull-requests-rest-decline)
                 (lambda (&rest _args) (setq called t))))
        (bitbucket-devops-pull-requests-ui-decline)
        (should-not called))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _args) t))
                ((symbol-function 'bitbucket-devops-pull-requests-rest-decline)
                 (lambda (_context _pull-request-id _callback)
                   (setq called t))))
        (bitbucket-devops-pull-requests-ui-decline)
        (should called)))))

(ert-deftest bitbucket-devops-pull-requests-ui-change-state-offers-open-actions ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        selections
        actions)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                  '((id . 11) (state . "OPEN") (draft . :false)))
      (cl-letf
          (((symbol-function 'completing-read)
            (lambda (_prompt candidates &rest _arguments)
              (push candidates selections)
              "Mark draft"))
           ((symbol-function 'bitbucket-devops-pull-requests-ui-mark-draft)
            (lambda () (interactive) (push 'draft actions))))
        (bitbucket-devops-pull-requests-ui-change-state))
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                  '((id . 11) (state . "OPEN") (draft . t)))
      (cl-letf
          (((symbol-function 'completing-read)
            (lambda (_prompt candidates &rest _arguments)
              (push candidates selections)
              "Mark ready for review"))
           ((symbol-function 'bitbucket-devops-pull-requests-ui-mark-ready)
            (lambda () (interactive) (push 'ready actions))))
        (bitbucket-devops-pull-requests-ui-change-state)))
    (should
     (equal
      (reverse selections)
      '(("Mark draft" "Merge" "Decline")
        ("Mark ready for review" "Decline"))))
    (should (equal (reverse actions) '(draft ready)))))

(ert-deftest bitbucket-devops-pull-requests-ui-change-state-rejects-terminal-state ()
  (with-temp-buffer
    (bitbucket-devops-pull-requests-detail-mode)
    (setq-local bitbucket-devops-pull-requests-ui--context
                '(:workspace "williseed1" :repo-slug "test"))
    (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
    (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                '((id . 11) (state . "MERGED") (draft . :false)))
    (should-error
     (bitbucket-devops-pull-requests-ui-change-state)
     :type 'user-error)))

(ert-deftest bitbucket-devops-pull-requests-ui-merge-confirms-and-posts-options ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed
        prompt)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local
       bitbucket-devops-pull-requests-ui--details-pull-request
       '((id . 11)
         (title . "Development")
         (state . "OPEN")
         (draft . :false)
         (source . ((branch . ((name . "development")))))
         (destination
          . ((branch . ((name . "main")
                        (merge_strategies . ("squash" "merge_commit"))
                        (default_merge_strategy . "squash")))))))
      (should
       (equal (bitbucket-devops-pull-requests-ui--merge-strategies)
              '("squash" "merge_commit")))
      (should
       (equal (bitbucket-devops-pull-requests-ui--default-merge-strategy)
              "squash"))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (question) (setq prompt question) t))
                ((symbol-function 'bitbucket-devops-pull-requests-rest-merge)
                 (lambda (request-context pull-request-id body _callback)
                   (setq observed
                         (list request-context pull-request-id body)))))
        (bitbucket-devops-pull-requests-ui-merge "squash" "Merge feature" nil)
        (should
         (equal
          observed
          (list
           context
           11
           '((type . "pullrequest")
             (merge_strategy . "squash")
             (close_source_branch . :false)
             (message . "Merge feature")))))
        (should
         (string-match-p
          "williseed1/test pull request #11 Development"
          prompt))
        (should (string-match-p "development -> main" prompt))))))

(ert-deftest bitbucket-devops-pull-requests-ui-merge-rejects-draft-or-closed-pr ()
  (with-temp-buffer
    (bitbucket-devops-pull-requests-detail-mode)
    (setq-local bitbucket-devops-pull-requests-ui--context
                '(:workspace "williseed1" :repo-slug "test"))
    (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
    (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                '((state . "OPEN") (draft . t)))
    (should-error
     (bitbucket-devops-pull-requests-ui-merge "merge_commit" "" nil)
     :type 'user-error)
    (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                '((state . "MERGED") (draft . :false)))
    (should-error
     (bitbucket-devops-pull-requests-ui-merge "merge_commit" "" nil)
     :type 'user-error)))

(ert-deftest bitbucket-devops-pull-requests-ui-detail-map-exposes-review-actions ()
  (dolist (binding '(("RET" . bitbucket-devops-pull-requests-ui-open-detail-at-point)
                     ("S-RET" . bitbucket-devops-pull-requests-ui-copy-browser-url-at-point)
                     ("S-<return>" . bitbucket-devops-pull-requests-ui-copy-browser-url-at-point)
                     ("a" . bitbucket-devops-pull-requests-ui-approve)
                     ("u" . bitbucket-devops-pull-requests-ui-remove-approval)
                     ("r" . bitbucket-devops-pull-requests-ui-refresh-current)
                     ("R" . bitbucket-devops-pull-requests-ui-toggle-draft)
                     ("C-c g" . bitbucket-devops-pull-requests-ui-refresh-current)
                     ("C-c d" . bitbucket-devops-pull-requests-ui-choose-diff-viewer)
                     ("m" . bitbucket-devops-pull-requests-ui-open-commits)
                     ("A" . bitbucket-devops-pull-requests-ui-open-activity)
                     ("P" . bitbucket-devops-pull-requests-ui-run-pipeline)
                     ("C-c P" . bitbucket-devops-pull-requests-ui-run-pipeline)
                     ("C-c b" . bitbucket-devops-pull-requests-ui-checkout-source-branch)
                     ("C-c w" . bitbucket-devops-pull-requests-ui-toggle-comment-watch)
                     ("C-c C-w" . bitbucket-devops-pull-requests-ui-toggle-comment-watch)
                     ("o" . bitbucket-devops-pull-requests-ui-browse)
                     ("x" . bitbucket-devops-pull-requests-ui-request-changes)
                     ("X" . bitbucket-devops-pull-requests-ui-remove-request-changes)
                     ("c" . bitbucket-devops-pull-requests-ui-add-comment)
                     ("C" . bitbucket-devops-pull-requests-ui-reply-to-comment)
                     ("C-c e" . bitbucket-devops-pull-requests-ui-edit-comment)
                     ("C-c i" . bitbucket-devops-pull-requests-ui-add-inline-comment)
                     ("C-c k" . bitbucket-devops-pull-requests-ui-delete-comment)
                     ("C-c r" . bitbucket-devops-pull-requests-ui-resolve-comment)
                     ("C-c o" . bitbucket-devops-pull-requests-ui-reopen-comment)
                     ("C-c +" . bitbucket-devops-pull-requests-ui-add-reviewer)
                     ("C-c =" . bitbucket-devops-pull-requests-ui-add-default-reviewers)
                     ("C-c -" . bitbucket-devops-pull-requests-ui-remove-reviewer)
                     ("M" . bitbucket-devops-pull-requests-ui-merge)
                     ("D" . bitbucket-devops-pull-requests-ui-decline)
                     ("?" . bitbucket-devops-ui-show-command-panel)))
    (should
     (eq (lookup-key bitbucket-devops-pull-requests-detail-mode-map
                     (kbd (car binding)))
         (cdr binding))))
  (should-not
   (lookup-key bitbucket-devops-pull-requests-detail-mode-map (kbd "K")))
  (dolist (key '("b" "B" "I"))
    (should-not
     (lookup-key bitbucket-devops-pull-requests-detail-mode-map (kbd key))))
  (should
   (eq (lookup-key bitbucket-devops-pull-requests-detail-mode-map (kbd "C-c t"))
       bitbucket-devops-pull-requests-task-prefix-map))
  (should
   (eq (lookup-key bitbucket-devops-pull-requests-detail-mode-map (kbd "C-c p"))
       bitbucket-devops-pull-requests-metadata-prefix-map))
  (dolist (binding '(("c" . bitbucket-devops-pull-requests-ui-create-task)
                     ("e" . bitbucket-devops-pull-requests-ui-edit-task)
                     ("d" . bitbucket-devops-pull-requests-ui-delete-task)
                     ("r" . bitbucket-devops-pull-requests-ui-resolve-task)
                     ("o" . bitbucket-devops-pull-requests-ui-reopen-task)))
    (should
     (eq (lookup-key bitbucket-devops-pull-requests-task-prefix-map
                     (kbd (car binding)))
         (cdr binding))))
  (dolist (binding '(("e" . bitbucket-devops-pull-requests-ui-edit-metadata)
                     ("d" . bitbucket-devops-pull-requests-ui-toggle-draft)))
    (should
     (eq (lookup-key bitbucket-devops-pull-requests-metadata-prefix-map
                     (kbd (car binding)))
         (cdr binding)))))

(ert-deftest bitbucket-devops-pull-requests-ui-refresh-aliases-include-detail-buffer ()
  (should
   (eq (lookup-key bitbucket-devops-pull-requests-list-mode-map (kbd "r"))
       #'bitbucket-devops-pull-requests-ui-refresh-current))
  (should
   (eq (lookup-key bitbucket-devops-pull-requests-diff-mode-map (kbd "r"))
       #'bitbucket-devops-pull-requests-ui-refresh-current))
  (dolist (map (list bitbucket-devops-pull-requests-commits-mode-map
                     bitbucket-devops-pull-requests-activity-mode-map))
    (should
     (eq (lookup-key map (kbd "r"))
         #'bitbucket-devops-pull-requests-ui-refresh-current)))
  (should
   (eq (lookup-key bitbucket-devops-pull-requests-detail-mode-map (kbd "r"))
       #'bitbucket-devops-pull-requests-ui-refresh-current))
  (should
   (eq (lookup-key bitbucket-devops-pull-requests-detail-mode-map (kbd "C-c g"))
       #'bitbucket-devops-pull-requests-ui-refresh-current))
  (should
   (eq (lookup-key bitbucket-devops-pull-requests-detail-mode-map (kbd "R"))
       #'bitbucket-devops-pull-requests-ui-toggle-draft))
  (dolist (key '("b" "B" "I"))
    (should-not
     (lookup-key bitbucket-devops-pull-requests-detail-mode-map (kbd key))))
  (dolist (key '("b" "B"))
    (should-not
     (lookup-key bitbucket-devops-pull-requests-list-mode-map (kbd key))))
  (dolist (mode '(bitbucket-devops-pull-requests-list-mode
                  bitbucket-devops-pull-requests-diff-mode
                  bitbucket-devops-pull-requests-commits-mode
                  bitbucket-devops-pull-requests-activity-mode))
    (with-temp-buffer
      (funcall mode)
      (should
       (eq (lookup-key (current-local-map) (kbd "?"))
           #'bitbucket-devops-ui-show-command-panel))
      (should
       (string-match-p
        "r[[:space:]]+Refresh"
        (bitbucket-devops-ui--command-panel-lines (current-buffer))))))
  (with-temp-buffer
    (bitbucket-devops-pull-requests-detail-mode)
    (should
     (string-match-p
      "r[[:space:]]+Refresh"
      (bitbucket-devops-ui--command-panel-lines (current-buffer))))
    (should
     (string-match-p
      "R[[:space:]]+Toggle ready/draft"
      (bitbucket-devops-ui--command-panel-lines (current-buffer))))))

(ert-deftest bitbucket-devops-pull-requests-ui-commit-map-opens-commit-at-point ()
  (should
   (eq (lookup-key bitbucket-devops-pull-requests-commits-mode-map (kbd "RET"))
       #'bitbucket-devops-pull-requests-ui-open-commit-at-point))
  (should
   (eq (lookup-key bitbucket-devops-pull-requests-commits-mode-map
                   (kbd "<mouse-1>"))
       #'bitbucket-devops-pull-requests-ui-open-commit-at-mouse))
  (with-temp-buffer
    (bitbucket-devops-pull-requests-commits-mode)
    (should
     (string-match-p
      "RET[[:space:]]+Open commit"
      (bitbucket-devops-ui--command-panel-lines (current-buffer))))))

(ert-deftest bitbucket-devops-pull-requests-ui-command-panels-show-pr-tools ()
  (dolist (mode '(bitbucket-devops-pull-requests-list-mode
                  bitbucket-devops-pull-requests-detail-mode))
    (with-temp-buffer
      (funcall mode)
      (should
       (string-match-p
        "P/C-c P[[:space:]]+Run pipeline"
        (bitbucket-devops-ui--command-panel-lines (current-buffer))))
      (should
       (string-match-p
        "C-c b[[:space:]]+Checkout branch"
        (bitbucket-devops-ui--command-panel-lines (current-buffer))))
      (should
       (string-match-p
        "C-c w/C-c C-w[[:space:]]+Watch comments"
        (bitbucket-devops-ui--command-panel-lines (current-buffer))))
      (should-not
       (string-match-p
        "\\(?:^\\|\n\\)b[[:space:]]+Checkout branch"
        (bitbucket-devops-ui--command-panel-lines (current-buffer)))))))

(ert-deftest bitbucket-devops-pull-requests-ui-command-panels-show-browser-actions ()
  (dolist (mode '(bitbucket-devops-pull-requests-list-mode
                  bitbucket-devops-pull-requests-detail-mode))
    (with-temp-buffer
      (funcall mode)
      (should
       (string-match-p
        "o[[:space:]]+Browser"
        (bitbucket-devops-ui--command-panel-lines (current-buffer)))))))

(ert-deftest bitbucket-devops-pull-requests-ui-command-panels-show-copy-link ()
  (dolist (mode '(bitbucket-devops-pull-requests-list-mode
                  bitbucket-devops-pull-requests-detail-mode))
    (with-temp-buffer
      (funcall mode)
      (should
       (string-match-p
        "S-RET[[:space:]]+Copy browser link"
        (bitbucket-devops-ui--command-panel-lines (current-buffer)))))))

(ert-deftest bitbucket-devops-pull-requests-ui-detail-command-panel-shows-enter-action ()
  (with-temp-buffer
    (bitbucket-devops-pull-requests-detail-mode)
    (should
     (string-match-p
      "RET[[:space:]]+Action at point"
      (bitbucket-devops-ui--command-panel-lines (current-buffer))))))

(ert-deftest bitbucket-devops-pull-requests-ui-command-panel-shows-diff-viewer-choice ()
  (with-temp-buffer
    (bitbucket-devops-pull-requests-detail-mode)
    (should
     (string-match-p
      "d/C-c d[[:space:]]+Diff / choose"
      (bitbucket-devops-ui--command-panel-lines (current-buffer))))))

(ert-deftest bitbucket-devops-pull-requests-ui-install-evil-bindings-covers-pr-actions ()
  (let ((prefix-bindings
         (list (kbd "C-u") #'universal-argument
               (kbd "SPC u") #'universal-argument))
        observed)
    (cl-letf (((symbol-function 'evil-define-key*)
               (lambda (&rest arguments) (push arguments observed))))
      (bitbucket-devops-pull-requests-ui--install-evil-bindings)
      (should (= (length observed) 11))
      (should
       (member
        (append
         (list 'normal bitbucket-devops-pull-requests-list-mode-map)
         prefix-bindings
         (list
          (kbd "r") #'bitbucket-devops-pull-requests-ui-refresh-current
          (kbd "C-c g") #'bitbucket-devops-pull-requests-ui-refresh-current
          (kbd "RET") #'bitbucket-devops-pull-requests-ui-open-at-point
          (kbd "S-RET") #'bitbucket-devops-pull-requests-ui-copy-browser-url-at-point
          (kbd "S-<return>")
          #'bitbucket-devops-pull-requests-ui-copy-browser-url-at-point
          (kbd "n") #'bitbucket-devops-pull-requests-ui-load-more
          (kbd "s") #'bitbucket-devops-pull-requests-ui-set-state-filter
          (kbd "f") #'bitbucket-devops-pull-requests-ui-set-branch-filter
          (kbd "a") #'bitbucket-devops-pull-requests-ui-set-author-filter
          (kbd "P") #'bitbucket-devops-pull-requests-ui-run-pipeline
          (kbd "C-c P") #'bitbucket-devops-pull-requests-ui-run-pipeline
          (kbd "C-c b") #'bitbucket-devops-pull-requests-ui-checkout-source-branch
          (kbd "C-c w") #'bitbucket-devops-pull-requests-ui-toggle-comment-watch
          (kbd "C-c C-w") #'bitbucket-devops-pull-requests-ui-toggle-comment-watch
          (kbd "o") #'bitbucket-devops-pull-requests-ui-browse
          (kbd "c") #'bitbucket-devops-pull-requests-ui-create
          (kbd "-") #'bitbucket-devops-ui-back
          (kbd "q") #'bitbucket-devops-ui-quit
          (kbd "?") #'bitbucket-devops-ui-show-command-panel))
        observed))
      (dolist (call observed)
        (when (> (length call) 4)
          (let ((arguments (cddr call)))
            (dolist (key '("C-u" "SPC u"))
              (let ((position (cl-position (kbd key) arguments :test #'equal)))
                (should position)
                (should (eq (nth (1+ position) arguments)
                            #'universal-argument)))))))
      (let* ((detail-call
              (seq-find
               (lambda (call)
                 (and
                  (eq (cadr call) bitbucket-devops-pull-requests-detail-mode-map)
                  (> (length call) 4)))
               observed))
             (arguments (cddr detail-call)))
        (should detail-call)
        (dolist
            (binding
             (list
              (cons (kbd "C-c k")
                    #'bitbucket-devops-pull-requests-ui-delete-comment)
              (cons (kbd "C-c g")
                    #'bitbucket-devops-pull-requests-ui-refresh-current)
              (cons (kbd "C-c d")
                    #'bitbucket-devops-pull-requests-ui-choose-diff-viewer)
              (cons (kbd "r")
                    #'bitbucket-devops-pull-requests-ui-refresh-current)
              (cons (kbd "R")
                    #'bitbucket-devops-pull-requests-ui-toggle-draft)
              (cons (kbd "P")
                    #'bitbucket-devops-pull-requests-ui-run-pipeline)
              (cons (kbd "C-c P")
                    #'bitbucket-devops-pull-requests-ui-run-pipeline)
              (cons (kbd "C-c b")
                    #'bitbucket-devops-pull-requests-ui-checkout-source-branch)
              (cons (kbd "C-c w")
                    #'bitbucket-devops-pull-requests-ui-toggle-comment-watch)
              (cons (kbd "C-c C-w")
                    #'bitbucket-devops-pull-requests-ui-toggle-comment-watch)
              (cons (kbd "o")
                    #'bitbucket-devops-pull-requests-ui-browse)
              (cons (kbd "C-c =")
                    #'bitbucket-devops-pull-requests-ui-add-default-reviewers)
              (cons (kbd "RET")
                    #'bitbucket-devops-pull-requests-ui-open-detail-at-point)
              (cons (kbd "S-RET")
                    #'bitbucket-devops-pull-requests-ui-copy-browser-url-at-point)
              (cons (kbd "S-<return>")
                    #'bitbucket-devops-pull-requests-ui-copy-browser-url-at-point)
              (cons (kbd "C-c t")
                    bitbucket-devops-pull-requests-task-prefix-map)
              (cons (kbd "C-c p")
                    bitbucket-devops-pull-requests-metadata-prefix-map)
              (cons (kbd "?")
                    #'bitbucket-devops-ui-show-command-panel)
              (cons (kbd "-") #'bitbucket-devops-ui-back)))
          (let ((position
                 (cl-position (car binding) arguments :test #'equal)))
            (should position)
            (should
             (eq (nth (1+ position) arguments) (cdr binding))))))
      (should
       (member
        (list
         'normal
         bitbucket-devops-pull-requests-detail-mode-map
         (kbd "K") nil)
        observed))
      (dolist (binding (list (cons bitbucket-devops-pull-requests-list-mode-map
                                   (kbd "b"))
                             (cons bitbucket-devops-pull-requests-list-mode-map
                                   (kbd "B"))
                             (cons bitbucket-devops-pull-requests-detail-mode-map
                                   (kbd "b"))
                             (cons bitbucket-devops-pull-requests-detail-mode-map
                                   (kbd "B"))
                             (cons bitbucket-devops-pull-requests-detail-mode-map
                                   (kbd "I"))))
        (should
         (member
          (list 'normal (car binding) (cdr binding) nil)
          observed)))
      (should
       (member
        (append
         (list 'normal bitbucket-devops-pull-requests-diff-mode-map)
         prefix-bindings
         (list
          (kbd "r") #'bitbucket-devops-pull-requests-ui-refresh-current
          (kbd "C-c g") #'bitbucket-devops-pull-requests-ui-refresh-current
          (kbd "i") #'bitbucket-devops-pull-requests-ui-add-inline-comment
          (kbd "C-c i") #'bitbucket-devops-pull-requests-ui-add-inline-comment
          (kbd "-") #'bitbucket-devops-ui-back
          (kbd "q") #'bitbucket-devops-ui-quit
          (kbd "?") #'bitbucket-devops-ui-show-command-panel))
        observed))
      (should
       (member
        (append
         (list 'normal bitbucket-devops-pull-requests-commits-mode-map)
         prefix-bindings
         (list
          (kbd "RET") #'bitbucket-devops-pull-requests-ui-open-commit-at-point
          (kbd "<mouse-1>") #'bitbucket-devops-pull-requests-ui-open-commit-at-mouse
          (kbd "r") #'bitbucket-devops-pull-requests-ui-refresh-current
          (kbd "C-c g") #'bitbucket-devops-pull-requests-ui-refresh-current
          (kbd "-") #'bitbucket-devops-ui-back
          (kbd "q") #'bitbucket-devops-ui-quit
          (kbd "?") #'bitbucket-devops-ui-show-command-panel))
        observed))
      (should
       (member
        (append
         (list 'normal bitbucket-devops-pull-requests-activity-mode-map)
         prefix-bindings
         (list
          (kbd "r") #'bitbucket-devops-pull-requests-ui-refresh-current
          (kbd "C-c g") #'bitbucket-devops-pull-requests-ui-refresh-current
          (kbd "-") #'bitbucket-devops-ui-back
          (kbd "q") #'bitbucket-devops-ui-quit
          (kbd "?") #'bitbucket-devops-ui-show-command-panel))
        observed)))))

(ert-deftest bitbucket-devops-pull-requests-ui-custom-keybindings-update-maps ()
  (let ((original bitbucket-devops-pull-requests-detail-keybindings))
    (unwind-protect
        (progn
          (setq bitbucket-devops-pull-requests-detail-keybindings
                (cons
                 '("C-c x" . bitbucket-devops-pull-requests-ui-delete-comment)
                 (seq-remove
                  (lambda (binding) (equal (car binding) "C-c k"))
                  bitbucket-devops-pull-requests-detail-keybindings)))
          (bitbucket-devops-pull-requests-ui-apply-keybindings)
          (should-not
           (lookup-key bitbucket-devops-pull-requests-detail-mode-map (kbd "C-c k")))
          (should
           (eq
            (lookup-key bitbucket-devops-pull-requests-detail-mode-map (kbd "C-c x"))
            #'bitbucket-devops-pull-requests-ui-delete-comment))
          (with-temp-buffer
            (bitbucket-devops-pull-requests-detail-mode)
            (should
             (string-match-p
              "C-c x"
              (bitbucket-devops-ui--command-panel-lines (current-buffer))))))
      (setq bitbucket-devops-pull-requests-detail-keybindings original)
      (bitbucket-devops-pull-requests-ui-apply-keybindings))))

(ert-deftest bitbucket-devops-pull-requests-ui-opens-commit-and-activity-subviews ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        (commits
         (alist-get
          'values
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-request-commits.json")))
        (activity
         (alist-get
          'values
          (bitbucket-devops-pull-requests-ui-test-read-json-fixture
           "pull-request-activity.json")))
        displayed)
    (unwind-protect
        (with-temp-buffer
          (bitbucket-devops-pull-requests-detail-mode)
          (setq-local bitbucket-devops-pull-requests-ui--context context)
          (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
          (setq-local bitbucket-devops-pull-requests-ui--details-commits commits)
          (setq-local bitbucket-devops-pull-requests-ui--details-activity activity)
          (cl-letf (((symbol-function 'bitbucket-devops-ui--display-buffer)
                     (lambda (buffer _select previous)
                       (push (list buffer previous) displayed)
                       buffer)))
            (bitbucket-devops-pull-requests-ui-open-commits)
            (bitbucket-devops-pull-requests-ui-open-activity))
          (with-current-buffer
              "*Bitbucket Pull Request Commits: williseed1/test#11*"
            (should (derived-mode-p 'bitbucket-devops-pull-requests-commits-mode))
            (should (string-match-p "83bd24f1234567890" (buffer-string)))
            (should (string-match-p "Merged in development" (buffer-string)))
            (goto-char (point-min))
            (search-forward "83bd24f1234567890")
            (should
             (eq (get-text-property (match-beginning 0) 'face)
                 'bitbucket-devops-pull-requests-commit-face))
            (should
             (equal
              (get-text-property
               (match-beginning 0) 'bitbucket-devops-pull-requests-commit-hash)
              "83bd24f1234567890")))
          (with-current-buffer
              "*Bitbucket Pull Request Activity: williseed1/test#11*"
            (should (derived-mode-p 'bitbucket-devops-pull-requests-activity-mode))
            (should (string-match-p "changed state to MERGED" (buffer-string)))
            (should (string-match-p "commented" (buffer-string)))
            (goto-char (point-min))
            (search-forward "MERGED")
            (should
             (eq (get-text-property (match-beginning 0) 'face)
                 'bitbucket-devops-pull-requests-merged-face)))
          (should (= (length displayed) 2)))
      (dolist (name '("*Bitbucket Pull Request Commits: williseed1/test#11*"
                      "*Bitbucket Pull Request Activity: williseed1/test#11*"))
        (when-let ((buffer (get-buffer name)))
          (kill-buffer buffer))))))

(ert-deftest bitbucket-devops-pull-requests-ui-opens-selected-commit-in-magit ()
  (let ((context '(:root "/tmp/repository/"
                   :workspace "williseed1"
                   :repo-slug "test"))
        ensured
        displayed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-commits-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (bitbucket-devops-pull-requests-ui--render-commits
       '(((hash . "83bd24f1234567890")
          (message . "Changed files")
          (author . ((raw . "Will Bosch <will@example.com>"))))))
      (goto-char (point-min))
      (search-forward "83bd24f1234567890")
      (cl-letf (((symbol-function
                  'bitbucket-devops-pull-requests-ui--ensure-commit-available)
                 (lambda (observed-context hash)
                   (setq ensured (list observed-context hash))))
                ((symbol-function 'magit-show-commit)
                 (lambda (hash &rest _arguments)
                   (setq displayed (list hash default-directory)))))
        (bitbucket-devops-pull-requests-ui-open-commit-at-point))
      (should (equal ensured (list context "83bd24f1234567890")))
      (should
       (equal displayed '("83bd24f1234567890" "/tmp/repository/"))))))

(ert-deftest bitbucket-devops-pull-requests-ui-magit-commit-removes-package-panel ()
  (let ((context '(:root "/tmp/repository/"
                   :workspace "williseed1"
                   :repo-slug "test"))
        (commits-buffer (generate-new-buffer "Bitbucket PR commits test"))
        panel-deleted)
    (unwind-protect
        (with-current-buffer commits-buffer
          (bitbucket-devops-pull-requests-commits-mode)
          (setq-local bitbucket-devops-pull-requests-ui--context context)
          (bitbucket-devops-pull-requests-ui--render-commits
           '(((hash . "83bd24f1234567890")
              (message . "Changed files"))))
          (goto-char (point-min))
          (search-forward "83bd24f1234567890")
          (cl-letf (((symbol-function
                      'bitbucket-devops-pull-requests-ui--ensure-commit-available)
                     #'ignore)
                    ((symbol-function 'magit-show-commit)
                     #'ignore)
                    ((symbol-function
                      'bitbucket-devops-ui--delete-command-panel)
                     (lambda ()
                       (setq panel-deleted t))))
            (bitbucket-devops-pull-requests-ui-open-commit-at-point))
          (should panel-deleted))
      (when (buffer-live-p commits-buffer)
        (kill-buffer commits-buffer)))))

(ert-deftest bitbucket-devops-pull-requests-ui-user-facing-buffer-names-are-special ()
  (let ((context '(:workspace "williseed1" :repo-slug "test")))
    (dolist
        (name
         (list
          (bitbucket-devops-pull-requests-ui--details-buffer-name context 11)
          (bitbucket-devops-pull-requests-ui--diff-buffer-name context 11)
          (bitbucket-devops-pull-requests-ui--subview-buffer-name
           "Commits" context 11)
          (format "*Bitbucket Pull Requests: %s/%s*"
                  (plist-get context :workspace)
                  (plist-get context :repo-slug))))
      (should (string-prefix-p "*" name))
      (should (string-suffix-p "*" name)))))

(ert-deftest bitbucket-devops-pull-requests-ui-refresh-current-refreshes-active-view ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-ui-refresh)
                 (lambda () (push 'list observed))))
        (bitbucket-devops-pull-requests-ui-refresh-current)))
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-ui-refresh-details)
                 (lambda () (push 'detail observed))))
        (bitbucket-devops-pull-requests-ui-refresh-current)))
    (with-temp-buffer
      (bitbucket-devops-pull-requests-diff-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local buffer-read-only t)
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-get-diff)
                 (lambda (_context _pull-request-id callback)
                   (push 'diff observed)
                   (funcall callback "+new\n" nil))))
        (bitbucket-devops-pull-requests-ui-refresh-current)
        (should (string-match-p "\\+new" (buffer-string)))))
    (with-temp-buffer
      (bitbucket-devops-pull-requests-commits-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-list-commits)
                 (lambda (_context _pull-request-id callback &optional _next)
                   (push 'commits observed)
                   (funcall callback
                            '((values . (((hash . "abc123")
                                          (message . "Updated")))))
                            nil))))
        (bitbucket-devops-pull-requests-ui-refresh-current)
        (should (string-match-p "abc123" (buffer-string)))))
    (with-temp-buffer
      (bitbucket-devops-pull-requests-activity-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-list-activity)
                 (lambda (_context _pull-request-id callback &optional _next)
                   (push 'activity observed)
                   (funcall callback
                            '((values . (((update . ((state . "OPEN")))))))
                            nil))))
        (bitbucket-devops-pull-requests-ui-refresh-current)
        (should (string-match-p "changed state to OPEN" (buffer-string)))))
    (should
     (equal (nreverse observed)
            '(list detail diff commits activity)))))

(ert-deftest bitbucket-devops-pull-requests-ui-details-use-package-navigation ()
  (let* ((context '(:workspace "williseed1" :repo-slug "test"))
         (pull-request '((id . 11) (title . "Development")))
         (previous (current-buffer))
         observed)
    (unwind-protect
        (cl-letf (((symbol-function 'bitbucket-devops-ui--display-buffer)
                   (lambda (buffer select previous-buffer)
                     (setq observed (list buffer select previous-buffer))
                     buffer))
                  ((symbol-function 'bitbucket-devops-pull-requests-ui-refresh-details)
                   #'ignore))
          (bitbucket-devops-pull-requests-ui-show-details context pull-request)
          (should (buffer-live-p (car observed)))
          (should (eq (nth 1 observed) t))
          (should (eq (nth 2 observed) previous)))
      (when-let ((buffer
                  (get-buffer
                   "*Bitbucket Pull Request: williseed1/test#11*")))
        (kill-buffer buffer)))))

(ert-deftest bitbucket-devops-pull-requests-ui-create-posts-and-opens-created-pr ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed
        refreshed
        opened)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (cl-letf (((symbol-function
                  'bitbucket-devops-pull-requests-ui--collect-open-pull-requests)
                 (lambda (_context callback &rest _)
                   (funcall callback nil nil)))
                ((symbol-function 'bitbucket-devops-pull-requests-rest-create)
                 (lambda (request-context body callback)
                   (setq observed (list request-context body))
                   (funcall callback '((id . 12) (title . "New PR")) nil)))
                ((symbol-function 'bitbucket-devops-pull-requests-ui-refresh)
                 (lambda () (setq refreshed t)))
                ((symbol-function 'bitbucket-devops-pull-requests-ui-show-details)
                 (lambda (request-context pull-request)
                   (setq opened (list request-context pull-request)))))
        (bitbucket-devops-pull-requests-ui-create
         "feature" "main" "New PR" "Description" t
         '("{reviewer}"))
        (should (equal (car observed) context))
        (should
         (equal
          (cadr observed)
          '((title . "New PR")
            (source . ((branch . ((name . "feature")))))
            (destination . ((branch . ((name . "main")))))
            (description . "Description")
            (draft . t)
            (reviewers . [((uuid . "{reviewer}"))]))))
        (should refreshed)
        (should
         (equal opened
                (list context '((id . 12) (title . "New PR")))))))))

(ert-deftest bitbucket-devops-pull-requests-ui-create-no-reviewers-skips-lookup ()
  (let (observed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (cl-letf
          (((symbol-function
             'bitbucket-devops-pull-requests-ui--load-reviewer-users)
            (lambda (&rest _arguments)
              (ert-fail "No-reviewer strategy loaded custom users")))
           ((symbol-function
             'bitbucket-devops-pull-requests-ui--collect-effective-default-reviewers)
            (lambda (&rest _arguments)
              (ert-fail "No-reviewer strategy loaded default reviewers")))
           ((symbol-function 'bitbucket-devops-pull-requests-ui-create)
            (lambda (&rest arguments) (setq observed arguments))))
        (bitbucket-devops-pull-requests-ui--create-with-reviewer-strategy
         (current-buffer)
         '("feature" "main" "Title" "Description" t)
         'none))
      (should
       (equal
        observed
        '("feature" "main" "Title" "Description" t :none))))))

(ert-deftest bitbucket-devops-pull-requests-ui-create-loads-default-reviewers ()
  (let (observed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (cl-letf
          (((symbol-function
             'bitbucket-devops-pull-requests-ui--collect-effective-default-reviewers)
            (lambda (_context callback &rest _arguments)
              (funcall
               callback
               '(((display_name . "Default") (uuid . "{default}")))
               nil)))
           ((symbol-function 'run-at-time)
            (lambda (_seconds _repeat function &rest arguments)
              (apply function arguments)))
           ((symbol-function 'bitbucket-devops-pull-requests-ui-create)
            (lambda (&rest arguments) (setq observed arguments))))
        (bitbucket-devops-pull-requests-ui--create-with-reviewer-strategy
         (current-buffer)
         '("feature" "main" "Title" "Description" t)
         'defaults))
      (should
       (equal
        observed
        '("feature" "main" "Title" "Description" t nil ("{default}")))))))

(ert-deftest bitbucket-devops-pull-requests-ui-create-applies-default-reviewers ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        created-body
        reviewer-body
        opened)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (cl-letf
          (((symbol-function
             'bitbucket-devops-pull-requests-ui--collect-open-pull-requests)
            (lambda (_context callback &rest _)
              (funcall callback nil nil)))
           ((symbol-function 'bitbucket-devops-pull-requests-rest-create)
            (lambda (_context body callback)
              (setq created-body body)
              (funcall
               callback
               '((id . 12)
                 (author . ((display_name . "Author") (uuid . "{author}"))))
               nil)))
           ((symbol-function 'bitbucket-devops-pull-requests-rest-update)
            (lambda (_context _pull-request-id body callback)
              (setq reviewer-body body)
              (funcall
               callback
               '((id . 12)
                 (reviewers . (((uuid . "{one}")) ((uuid . "{two}")))))
               nil)))
           ((symbol-function 'bitbucket-devops-pull-requests-ui-refresh)
            #'ignore)
           ((symbol-function 'bitbucket-devops-pull-requests-ui-show-details)
            (lambda (_context pull-request) (setq opened pull-request))))
        (bitbucket-devops-pull-requests-ui-create
         "feature" "main" "Title" "Description" t nil
         '("{author}" "{one}" "{two}")))
      (should-not (assq 'reviewers created-body))
      (should
       (equal
        reviewer-body
        '((reviewers . [((uuid . "{one}")) ((uuid . "{two}"))]))))
      (should (= (length (alist-get 'reviewers opened)) 2)))))

(ert-deftest bitbucket-devops-pull-requests-ui-create-offers-three-reviewer-strategies ()
  (let (offered default)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt collection _predicate require-match
                               &rest arguments)
                 (should (equal prompt "Reviewers: "))
                 (should require-match)
                 (setq offered collection
                       default (nth 2 arguments))
                 "No reviewers")))
      (should
       (eq (bitbucket-devops-pull-requests-ui--read-reviewer-strategy) 'none)))
    (should
     (equal
      (mapcar #'car offered)
      '("No reviewers" "Default reviewers" "Custom reviewers")))
    (should (equal default "Default reviewers"))))

(ert-deftest bitbucket-devops-pull-requests-ui-create-title-defaults-to-source-branch ()
  (let (title-initial)
    (with-temp-buffer
      (setq-local bitbucket-devops-pull-requests-ui--context
                  '(:workspace "williseed1"
                    :repo-slug "test"
                    :branch "feature/example"))
      (cl-letf (((symbol-function
                  'bitbucket-devops-pull-requests-ui--branch-names)
                 (lambda () '("feature/example" "main")))
                ((symbol-function 'completing-read)
                 (lambda (prompt _collection &optional _predicate
                                 _require-match _initial-input _history default)
                   (pcase prompt
                     ("Source branch: "
                      (should (equal default "feature/example"))
                      "feature/example")
                     ("Destination branch: "
                      (should (equal default "main"))
                      "main")
                     (_ (ert-fail (format "Unexpected prompt: %s" prompt))))))
                ((symbol-function 'read-string)
                 (lambda (prompt &optional initial-input &rest _args)
                   (pcase prompt
                     ("Pull request title: "
                      (setq title-initial initial-input)
                      initial-input)
                     ("Create as draft? [Y/n]: " "n")
                     (_ (ert-fail (format "Unexpected prompt: %s" prompt)))))))
        (should
         (equal
          (bitbucket-devops-pull-requests-ui--read-create-metadata)
          '(:source "feature/example"
            :destination "main"
            :title "feature/example"
            :draft nil)))))
    (should (equal title-initial "feature/example"))))

(ert-deftest bitbucket-devops-pull-requests-ui-create-arguments-title-defaults-to-source-branch ()
  (let (title-initial)
    (with-temp-buffer
      (setq-local bitbucket-devops-pull-requests-ui--context
                  '(:workspace "williseed1"
                    :repo-slug "test"
                    :branch "feature/example"))
      (cl-letf (((symbol-function
                  'bitbucket-devops-pull-requests-ui--branch-names)
                 (lambda () '("feature/example" "main")))
                ((symbol-function 'completing-read)
                 (lambda (prompt _collection &optional _predicate
                                 _require-match _initial-input _history default)
                   (pcase prompt
                     ("Source branch: "
                      (should (equal default "feature/example"))
                      "feature/example")
                     ("Destination branch: "
                      (should (equal default "main"))
                      "main")
                     (_ (ert-fail (format "Unexpected prompt: %s" prompt))))))
                ((symbol-function 'read-string)
                 (lambda (prompt &optional initial-input &rest _args)
                   (pcase prompt
                     ("Pull request title: "
                      (setq title-initial initial-input)
                      initial-input)
                     ("Description (optional): " "")
                     ("Create as draft? [Y/n]: " "n")
                     (_ (ert-fail (format "Unexpected prompt: %s" prompt)))))))
        (should
         (equal
          (bitbucket-devops-pull-requests-ui--read-create-arguments)
          '("feature/example" "main" "feature/example" "" nil)))))
    (should (equal title-initial "feature/example"))))

(ert-deftest bitbucket-devops-pull-requests-ui-create-opens-description-editor ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        editor
        display-action)
    (unwind-protect
        (with-temp-buffer
          (bitbucket-devops-pull-requests-list-mode)
          (setq-local bitbucket-devops-pull-requests-ui--context context)
          (cl-letf
              (((symbol-function
                 'bitbucket-devops-pull-requests-ui--read-reviewer-strategy)
                (lambda () 'defaults))
               ((symbol-function
                 'bitbucket-devops-pull-requests-ui--read-create-metadata)
                (lambda ()
                  '(:source "feature"
                    :destination "main"
                    :title "New PR"
                    :draft t)))
               ((symbol-function 'display-buffer)
                (lambda (buffer action)
                  (setq editor buffer
                        display-action action)
                  nil)))
            (bitbucket-devops-pull-requests-ui--create-interactively))
          (should (buffer-live-p editor))
          (with-current-buffer editor
            (should (equal (buffer-string) ""))
            (should bitbucket-devops-pull-requests-create-description-mode)
            (should (memq major-mode '(markdown-mode text-mode)))
            (should
             (equal
              bitbucket-devops-pull-requests-ui--create-metadata
              '(:source "feature"
                :destination "main"
                :title "New PR"
                :draft t)))
            (should
             (eq bitbucket-devops-pull-requests-ui--create-reviewer-strategy
                 'defaults))
            (should
             (eq (key-binding (kbd "C-c C-c"))
                 #'bitbucket-devops-pull-requests-ui-save-create-description)))
          (should
           (equal
            display-action
            '((display-buffer-in-side-window)
              (side . right)
              (slot . 1)
              (window-width . 0.45)))))
      (when (buffer-live-p editor)
        (with-current-buffer editor (set-buffer-modified-p nil))
        (kill-buffer editor)))))

(ert-deftest bitbucket-devops-pull-requests-ui-create-description-save-continues ()
  (let ((source (generate-new-buffer " *bitbucket-pr-create-source*"))
        (editor (generate-new-buffer " *bitbucket-pr-create-editor*"))
        observed)
    (unwind-protect
        (progn
          (with-current-buffer source
            (bitbucket-devops-pull-requests-list-mode)
            (setq-local bitbucket-devops-pull-requests-ui--context
                        '(:workspace "williseed1" :repo-slug "test")))
          (with-current-buffer editor
            (text-mode)
            (bitbucket-devops-pull-requests-create-description-mode 1)
            (setq-local bitbucket-devops-pull-requests-ui--create-source-buffer
                        source)
            (setq-local bitbucket-devops-pull-requests-ui--create-metadata
                        '(:source "feature"
                          :destination "main"
                          :title "New PR"
                          :draft t))
            (setq-local bitbucket-devops-pull-requests-ui--create-reviewer-strategy
                        'none)
            (insert "## Summary\n\nCreated from Markdown.\n")
            (cl-letf
                (((symbol-function
                   'bitbucket-devops-pull-requests-ui--create-with-reviewer-strategy)
                  (lambda (buffer create-arguments strategy)
                    (setq observed
                          (list buffer create-arguments strategy)))))
              (bitbucket-devops-pull-requests-ui-save-create-description)))
          (should
           (equal
            observed
            (list
             source
             '("feature" "main" "New PR"
               "## Summary\n\nCreated from Markdown.\n"
               t)
             'none))))
      (when (buffer-live-p editor)
        (with-current-buffer editor (set-buffer-modified-p nil))
        (kill-buffer editor))
      (when (buffer-live-p source)
        (kill-buffer source)))))

(ert-deftest bitbucket-devops-pull-requests-ui-create-custom-reviewers-loads-users ()
  (let (loaded observed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (cl-letf
          (((symbol-function
             'bitbucket-devops-pull-requests-ui--load-reviewer-users)
            (lambda (callback &rest _arguments)
              (setq loaded t)
              (funcall
               callback
               '(((display_name . "Grace Hopper") (uuid . "{grace}")))
               nil)))
           ((symbol-function 'run-at-time)
            (lambda (_seconds _repeat function &rest arguments)
              (apply function arguments)))
           ((symbol-function 'completing-read-multiple)
            (lambda (_prompt collection &rest _arguments)
              (list (caar collection))))
           ((symbol-function 'bitbucket-devops-pull-requests-ui-create)
            (lambda (&rest arguments) (setq observed arguments))))
        (bitbucket-devops-pull-requests-ui--create-with-reviewer-strategy
         (current-buffer)
         '("feature" "main" "Title" "Description" t)
         'custom))
      (should loaded)
      (should
       (equal
        observed
        '("feature" "main" "Title" "Description" t ("{grace}")))))))

(ert-deftest bitbucket-devops-pull-requests-ui-create-selects-reviewers-by-name ()
  (let ((buffer (generate-new-buffer " *bitbucket-pr-create-reviewers*"))
        observed
        offered)
    (unwind-protect
        (with-current-buffer buffer
          (bitbucket-devops-pull-requests-list-mode)
          (setq-local bitbucket-devops-pull-requests-ui--context
                      '(:workspace "williseed1" :repo-slug "test"))
          (cl-letf (((symbol-function 'completing-read-multiple)
                     (lambda (prompt collection &rest _arguments)
                       (should (equal prompt "Custom reviewers: "))
                       (setq offered collection)
                       (list (caar collection))))
                    ((symbol-function 'bitbucket-devops-pull-requests-ui-create)
                     (lambda (&rest arguments) (setq observed arguments))))
            (bitbucket-devops-pull-requests-ui--prompt-create-reviewers
             buffer
             '("feature" "main" "Title" "Description" t)
             '(((user . ((display_name . "Grace Hopper")
                         (nickname . "grace")
                         (uuid . "{grace}")))))
             nil))
          (should (string-match-p "Grace Hopper (@grace)" (caar offered)))
          (should
           (equal
            observed
            '("feature" "main" "Title" "Description" t ("{grace}")))))
      (kill-buffer buffer))))

(ert-deftest bitbucket-devops-pull-requests-ui-create-error-does-not-refresh-or-open ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        refreshed
        opened)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (cl-letf (((symbol-function
                  'bitbucket-devops-pull-requests-ui--collect-open-pull-requests)
                 (lambda (_context callback &rest _)
                   (funcall callback nil nil)))
                ((symbol-function 'bitbucket-devops-pull-requests-rest-create)
                 (lambda (_context _body callback)
                   (funcall callback nil '(:message "Missing scope"))))
                ((symbol-function 'bitbucket-devops-pull-requests-ui-refresh)
                 (lambda () (setq refreshed t)))
                ((symbol-function 'bitbucket-devops-pull-requests-ui-show-details)
                 (lambda (&rest _arguments) (setq opened t))))
        (bitbucket-devops-pull-requests-ui-create
         "feature" "main" "New PR" "" nil nil)
        (should-not refreshed)
        (should-not opened)))))

(ert-deftest bitbucket-devops-pull-requests-ui-collects-all-open-pull-requests ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        (next-url
         (concat
          "https://api.bitbucket.org/2.0/repositories/williseed1/test/"
          "pullrequests?page=2"))
        requests
        collected)
    (cl-letf
        (((symbol-function 'bitbucket-devops-pull-requests-rest-list)
          (lambda (request-context callback &optional next state)
            (push (list request-context next state) requests)
            (if next
                (funcall callback '((values . (((id . 2))))) nil)
              (funcall callback
                       `((values . (((id . 1)))) (next . ,next-url))
                       nil)))))
      (bitbucket-devops-pull-requests-ui--collect-open-pull-requests
       context
       (lambda (pull-requests error)
         (should-not error)
         (setq collected pull-requests)))
      (should (equal (mapcar (lambda (pull-request)
                               (alist-get 'id pull-request))
                             collected)
                     '(1 2)))
      (should
       (equal
        (nreverse requests)
        (list (list context nil "OPEN")
              (list context next-url "OPEN")))))))

(ert-deftest bitbucket-devops-pull-requests-ui-create-cancels-existing-branch-pair ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        posted
        reported)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (cl-letf
          (((symbol-function
             'bitbucket-devops-pull-requests-ui--collect-open-pull-requests)
            (lambda (_context callback &rest _)
              (funcall
               callback
               '(((id . 2)
                  (source . ((branch . ((name . "test")))))
                  (destination . ((branch . ((name . "main")))))))
               nil)))
           ((symbol-function 'bitbucket-devops-pull-requests-rest-create)
            (lambda (&rest _arguments) (setq posted t)))
           ((symbol-function 'message)
            (lambda (format-string &rest arguments)
              (setq reported (apply #'format format-string arguments)))))
        (bitbucket-devops-pull-requests-ui-create
         " test " "main " "Duplicate" "" t nil)
        (should-not posted)
        (should
         (equal
          reported
          (concat "Open Bitbucket pull request #2 already exists for "
                  "test -> main; creation cancelled")))))))

(ert-deftest bitbucket-devops-pull-requests-ui-create-stops-on-preflight-error ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        posted
        reported)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (cl-letf
          (((symbol-function
             'bitbucket-devops-pull-requests-ui--collect-open-pull-requests)
            (lambda (_context callback &rest _)
              (funcall callback nil '(:message "Request failed"))))
           ((symbol-function 'bitbucket-devops-pull-requests-rest-create)
            (lambda (&rest _arguments) (setq posted t)))
           ((symbol-function 'message)
            (lambda (format-string &rest arguments)
              (setq reported (apply #'format format-string arguments)))))
        (bitbucket-devops-pull-requests-ui-create
         "test" "main" "Duplicate" "" t nil)
        (should-not posted)
        (should
         (equal reported
                (concat "Unable to check existing Bitbucket pull requests: "
                        "Request failed")))))))

(ert-deftest bitbucket-devops-pull-requests-ui-draft-prompt-defaults-to-yes ()
  (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
    (should (bitbucket-devops-pull-requests-ui--read-draft-p)))
  (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "yes")))
    (should (bitbucket-devops-pull-requests-ui--read-draft-p)))
  (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "n")))
    (should-not (bitbucket-devops-pull-requests-ui--read-draft-p))))

(ert-deftest bitbucket-devops-pull-requests-ui-parses-reviewer-identifiers ()
  (should
   (equal
    (bitbucket-devops-pull-requests-ui--parse-reviewers
     " {first}, account-id, {first}, , second ")
    '("{first}" "account-id" "second"))))

(ert-deftest bitbucket-devops-pull-requests-ui-edit-metadata-preserves-draft-state ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local
       bitbucket-devops-pull-requests-ui--details-pull-request
       '((title . "Old")
         (description . "Old description")
         (draft . t)))
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-update)
                 (lambda (request-context pull-request-id body _callback)
                   (setq observed
                         (list request-context pull-request-id body)))))
        (bitbucket-devops-pull-requests-ui-edit-metadata "New" "New description")
        (should
         (equal
          observed
          (list
           context
           11
           '((title . "New")
             (description . "New description")
             (draft . t)))))))))

(ert-deftest bitbucket-devops-pull-requests-ui-description-opens-side-editor ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        (description "# Summary\n\n- first\n- second")
        editor
        display-action)
    (unwind-protect
        (with-temp-buffer
          (bitbucket-devops-pull-requests-detail-mode)
          (setq-local bitbucket-devops-pull-requests-ui--context context)
          (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
          (setq-local
           bitbucket-devops-pull-requests-ui--details-pull-request
           `((title . "Markdown PR")
             (description . ((raw . ,description)))
             (draft . :false)))
          (cl-letf (((symbol-function 'display-buffer)
                     (lambda (buffer action)
                       (setq display-action action)
                       (setq editor buffer)
                       nil)))
            (bitbucket-devops-pull-requests-ui-edit-description))
          (should (buffer-live-p editor))
          (with-current-buffer editor
            (should (equal (buffer-string) description))
            (should bitbucket-devops-pull-requests-description-edit-mode)
            (should (memq major-mode '(markdown-mode text-mode)))
            (should
             (eq (key-binding (kbd "C-c C-c"))
                 #'bitbucket-devops-pull-requests-ui-save-description)))
          (should
           (equal
            display-action
            '((display-buffer-in-side-window)
              (side . right)
              (slot . 1)
              (window-width . 0.45)))))
      (when (buffer-live-p editor)
        (with-current-buffer editor (set-buffer-modified-p nil))
        (kill-buffer editor)))))

(ert-deftest bitbucket-devops-pull-requests-ui-description-save-posts-markdown ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        (source (generate-new-buffer " *bitbucket-pr-description-source*"))
        (editor (generate-new-buffer " *bitbucket-pr-description-editor*"))
        observed)
    (unwind-protect
        (progn
          (with-current-buffer source
            (bitbucket-devops-pull-requests-detail-mode)
            (setq-local bitbucket-devops-pull-requests-ui--context context)
            (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
            (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                        '((title . "Old")
                          (description . "Old body")
                          (draft . t))))
          (with-current-buffer editor
            (text-mode)
            (bitbucket-devops-pull-requests-description-edit-mode 1)
            (setq-local bitbucket-devops-pull-requests-ui--description-source-buffer
                        source)
            (setq-local bitbucket-devops-pull-requests-ui--description-title
                        "New title")
            (insert "## Details\n\n```elisp\n(message \"hello\")\n```\n")
            (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-update)
                       (lambda (request-context pull-request-id body _callback)
                         (setq observed
                               (list request-context pull-request-id body)))))
              (bitbucket-devops-pull-requests-ui-save-description)))
          (should
           (equal
            observed
            (list
             context
             11
             '((title . "New title")
               (description . "## Details\n\n```elisp\n(message \"hello\")\n```\n")
               (draft . t))))))
      (when (buffer-live-p editor)
        (with-current-buffer editor (set-buffer-modified-p nil))
        (kill-buffer editor))
      (when (buffer-live-p source)
        (kill-buffer source)))))

(ert-deftest bitbucket-devops-pull-requests-ui-description-save-recovers-from-errors ()
  (let ((source (generate-new-buffer " *bitbucket-pr-description-source*")))
    (unwind-protect
        (with-temp-buffer
          (text-mode)
          (bitbucket-devops-pull-requests-description-edit-mode 1)
          (setq-local bitbucket-devops-pull-requests-ui--description-source-buffer
                      source)
          (setq-local bitbucket-devops-pull-requests-ui--description-title
                      "Title")
          (with-current-buffer source
            (bitbucket-devops-pull-requests-detail-mode)
            (setq-local bitbucket-devops-pull-requests-ui--context
                        '(:workspace "williseed1" :repo-slug "test"))
            (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id
                        11)
            (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                        '((title . "Title") (draft . :false))))
          (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-update)
                     (lambda (&rest _arguments)
                       (user-error "Authentication failed"))))
            (should-error
             (bitbucket-devops-pull-requests-ui-save-description)
             :type 'user-error))
          (should-not bitbucket-devops-pull-requests-ui--description-saving)
          (setq-local bitbucket-devops-pull-requests-ui--description-saving t)
          (should-error
           (bitbucket-devops-pull-requests-ui-cancel-description-edit)
           :type 'user-error))
      (when (buffer-live-p source)
        (kill-buffer source)))))

(ert-deftest bitbucket-devops-pull-requests-ui-metadata-key-opens-description-editor ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        opened-title)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                  '((title . "Old title") (description . "Body")))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (prompt initial-input &rest _arguments)
                   (should (equal prompt "Pull request title: "))
                   (should (equal initial-input "Old title"))
                   "New title"))
                ((symbol-function
                  'bitbucket-devops-pull-requests-ui--open-description-editor)
                 (lambda (title) (setq opened-title title))))
        (call-interactively #'bitbucket-devops-pull-requests-ui-edit-metadata)))
    (should (equal opened-title "New title"))))

(ert-deftest bitbucket-devops-pull-requests-ui-toggle-draft-updates-current-metadata ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local
       bitbucket-devops-pull-requests-ui--details-pull-request
       '((title . "Ready")
         (description . ((raw . "Body")))
         (draft . :false)))
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-update)
                 (lambda (_context _pull-request-id body _callback)
                   (setq observed body))))
        (bitbucket-devops-pull-requests-ui-toggle-draft)
        (should
         (equal
          observed
          '((title . "Ready")
            (description . "Body")
            (draft . t))))))))

(ert-deftest bitbucket-devops-pull-requests-ui-mark-ready-and-draft-are-deterministic ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local
       bitbucket-devops-pull-requests-ui--details-pull-request
       '((title . "Title")
         (description . ((raw . "Body")))
         (draft . t)))
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-update)
                 (lambda (_context _pull-request-id body _callback)
                   (push body observed))))
        (bitbucket-devops-pull-requests-ui-mark-ready)
        (setq-local
         bitbucket-devops-pull-requests-ui--details-pull-request
         '((title . "Title")
           (description . ((raw . "Body")))
           (draft . :false)))
        (bitbucket-devops-pull-requests-ui-mark-draft)
        (should
         (equal
          (reverse observed)
          '(((title . "Title")
             (description . "Body")
             (draft . :false))
            ((title . "Title")
             (description . "Body")
             (draft . t)))))))))

(ert-deftest bitbucket-devops-pull-requests-ui-add-reviewer-preserves-existing-reviewers ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local
       bitbucket-devops-pull-requests-ui--details-pull-request
       '((reviewers . (((display_name . "Ada") (uuid . "{ada}"))))))
      (cl-letf (((symbol-function 'bitbucket-devops-pull-requests-rest-update)
                 (lambda (request-context pull-request-id body _callback)
                   (setq observed
                         (list request-context pull-request-id body)))))
        (bitbucket-devops-pull-requests-ui-add-reviewer "account-grace")
        (should
         (equal
          observed
          (list
           context
           11
           '((reviewers
              . [((uuid . "{ada}"))
                 ((account_id . "account-grace"))])))))))))

(ert-deftest bitbucket-devops-pull-requests-ui-reviewer-candidates-use-readable-identities ()
  (let* ((users
          '(((user . ((display_name . "Ada Lovelace")
                      (nickname . "ada")
                      (email . "ada@example.com")
                      (uuid . "{12345678-aaaa-bbbb-cccc-123456789012}"))))
            ((display_name . "Ada Lovelace")
             (nickname . "ada-two")
             (uuid . "{87654321-aaaa-bbbb-cccc-123456789012}"))
            ((display_name . "Ada Lovelace")
             (nickname . "duplicate")
             (uuid . "{12345678-aaaa-bbbb-cccc-123456789012}"))))
         (candidates
          (bitbucket-devops-pull-requests-ui--reviewer-user-candidates users)))
    (should (= (length candidates) 2))
    (should
     (equal
      candidates
      '(("Ada Lovelace (@ada) <ada@example.com> [12345678]"
         . "{12345678-aaaa-bbbb-cccc-123456789012}")
        ("Ada Lovelace (@ada-two) [87654321]"
         . "{87654321-aaaa-bbbb-cccc-123456789012}"))))))

(ert-deftest bitbucket-devops-pull-requests-ui-reviewer-discovery-handles-nested-api-fields ()
  (let* ((response
          '((type . "repository_permission")
            (permission . "admin")
            (links . ((self . ((href . "https://example.test/permission")))))
            (user . ((type . "user")
                     (display_name . "Grace Hopper")
                     (nickname . "grace")
                     (uuid . "{eb2296a6-8478-44c1-8ac0-d63ca81c829c}")
                     (links . ((html . ((href . "https://example.test/grace")))))))))
         (users
          (bitbucket-devops-pull-requests-ui--collect-user-objects response)))
    (should (= (length users) 1))
    (should (equal (alist-get 'display_name (car users)) "Grace Hopper"))
    (should
     (equal
      (bitbucket-devops-pull-requests-ui--reviewer-user-candidates users)
      '(("Grace Hopper (@grace) [eb2296a6]"
         . "{eb2296a6-8478-44c1-8ac0-d63ca81c829c}"))))))

(ert-deftest bitbucket-devops-pull-requests-ui-reviewer-discovery-ignores-dotted-fields ()
  (should-not
   (bitbucket-devops-pull-requests-ui--collect-user-objects
    '(uuid . "{eb2296a6-8478-44c1-8ac0-d63ca81c829c}"))))

(ert-deftest bitbucket-devops-pull-requests-ui-add-reviewer-selects-name-and-sends-uuid ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed
        offered)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local
       bitbucket-devops-pull-requests-ui--details-pull-request
       '((author . ((display_name . "Author") (uuid . "{author}")))
         (reviewers . (((display_name . "Existing")
                        (uuid . "{existing}"))))))
      (cl-letf (((symbol-function
                  'bitbucket-devops-pull-requests-ui--load-reviewer-users)
                 (lambda (callback)
                   (funcall
                    callback
                    '(((user . ((display_name . "Author")
                                (nickname . "author")
                                (uuid . "{author}"))))
                      ((user . ((display_name . "Existing")
                                (nickname . "existing")
                                (uuid . "{existing}"))))
                      ((user . ((display_name . "Grace Hopper")
                                (nickname . "grace")
                                (uuid . "{grace}")))))
                    nil)))
                ((symbol-function 'run-at-time)
                 (lambda (_seconds _repeat function &rest arguments)
                   (apply function arguments)))
                ((symbol-function 'completing-read)
                 (lambda (prompt collection &rest _arguments)
                   (should (equal prompt "Add reviewer: "))
                   (setq offered collection)
                   (caar collection)))
                ((symbol-function 'bitbucket-devops-pull-requests-rest-update)
                 (lambda (request-context pull-request-id body _callback)
                   (setq observed
                         (list request-context pull-request-id body)))))
        (bitbucket-devops-pull-requests-ui-add-reviewer)
        (should (= (length offered) 1))
        (should (string-match-p "Grace Hopper (@grace)" (caar offered)))
        (should
         (equal
          observed
          (list
           context
           11
           '((reviewers
              . [((uuid . "{existing}"))
                 ((uuid . "{grace}"))])))))))))

(ert-deftest bitbucket-devops-pull-requests-ui-add-default-reviewers-appends-missing ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local
       bitbucket-devops-pull-requests-ui--details-pull-request
       '((author . ((display_name . "Author") (uuid . "{author}")))
         (reviewers . (((display_name . "Existing")
                        (uuid . "{existing}"))))))
      (cl-letf
          (((symbol-function
             'bitbucket-devops-pull-requests-ui--collect-effective-default-reviewers)
            (lambda (_context callback &rest _arguments)
              (funcall
               callback
               '(((display_name . "Author") (uuid . "{author}"))
                 ((display_name . "Existing") (uuid . "{existing}"))
                 ((display_name . "Default") (uuid . "{default}")))
               nil)))
           ((symbol-function 'run-at-time)
            (lambda (_seconds _repeat function &rest arguments)
              (apply function arguments)))
           ((symbol-function 'bitbucket-devops-pull-requests-rest-update)
            (lambda (request-context pull-request-id body _callback)
              (setq observed
                    (list request-context pull-request-id body)))))
        (bitbucket-devops-pull-requests-ui-add-default-reviewers)
        (should
         (equal
          observed
          (list
           context
           11
           '((reviewers
              . [((uuid . "{existing}"))
                 ((uuid . "{default}"))])))))))))

(ert-deftest bitbucket-devops-pull-requests-ui-load-reviewers-uses-cache ()
  (let (observed)
    (cl-letf
        (((symbol-function
           'bitbucket-devops-pull-requests-ui--known-reviewer-users)
          (lambda (&optional _context)
            '(((display_name . "Known") (uuid . "{known}")))))
         ((symbol-function 'bitbucket-devops-cache-reviewer-users-cached-p)
          (lambda (_context) t))
         ((symbol-function 'bitbucket-devops-cache-reviewer-users)
          (lambda (_context)
            '(((display_name . "Cached") (uuid . "{cached}")))))
         ((symbol-function
           'bitbucket-devops-pull-requests-ui--collect-user-pages)
          (lambda (&rest _arguments)
            (ert-fail "Cached reviewer lookup called Bitbucket"))))
      (with-temp-buffer
        (setq-local bitbucket-devops-pull-requests-ui--context
                    '(:workspace "williseed1" :repo-slug "test"))
        (bitbucket-devops-pull-requests-ui--load-reviewer-users
         (lambda (users error) (setq observed (list users error))))))
    (should-not (cadr observed))
    (should
     (equal
      (mapcar
       #'bitbucket-devops-pull-requests-ui--reviewer-identifier
       (car observed))
      '("{cached}" "{known}")))))

(ert-deftest bitbucket-devops-pull-requests-ui-load-reviewers-falls-back-to-workspace ()
  (let (observed cached)
    (cl-letf (((symbol-function
                'bitbucket-devops-pull-requests-ui--known-reviewer-users)
               (lambda (&optional _context)
                 '(((display_name . "Known") (uuid . "{known}")))))
              ((symbol-function 'bitbucket-devops-cache-reviewer-users-cached-p)
               (lambda (_context) nil))
              ((symbol-function 'bitbucket-devops-cache-put-reviewer-users)
               (lambda (_context users) (setq cached users)))
              ((symbol-function
                'bitbucket-devops-pull-requests-ui--collect-user-pages)
               (lambda (function _context callback &rest _arguments)
                 (if (eq function
                         #'bitbucket-devops-pull-requests-rest-list-repository-users)
                     (funcall callback nil '(:status 403 :message "Forbidden"))
                   (funcall
                    callback
                    '(((user . ((display_name . "Workspace User")
                                (uuid . "{workspace}")))))
                    nil)))))
      (with-temp-buffer
        (setq-local bitbucket-devops-pull-requests-ui--context
                    '(:workspace "williseed1" :repo-slug "test"))
        (bitbucket-devops-pull-requests-ui--load-reviewer-users
         (lambda (users error) (setq observed (list users error))))))
    (should-not (cadr observed))
    (should (= (length (car observed)) 2))
    (should (equal cached (car observed)))))

(ert-deftest bitbucket-devops-pull-requests-ui-refresh-reviewer-cache-forces-lookup ()
  (let (force context)
    (with-temp-buffer
      (setq-local bitbucket-devops-pull-requests-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (cl-letf
          (((symbol-function
             'bitbucket-devops-pull-requests-ui--load-reviewer-users)
            (lambda (callback refresh request-context)
              (setq force refresh
                    context request-context)
              (funcall callback nil nil))))
        (bitbucket-devops-pull-requests-refresh-reviewer-cache)))
    (should force)
    (should
     (equal context '(:workspace "williseed1" :repo-slug "test")))))

(ert-deftest bitbucket-devops-pull-requests-ui-reviewer-update-rejects-missing-identifiers ()
  (with-temp-buffer
    (bitbucket-devops-pull-requests-detail-mode)
    (setq-local
     bitbucket-devops-pull-requests-ui--details-pull-request
     '((reviewers . (((display_name . "Unknown identifier"))))))
    (should-error
     (bitbucket-devops-pull-requests-ui--reviewer-identifiers)
     :type 'user-error)))

(ert-deftest bitbucket-devops-pull-requests-ui-remove-reviewer-confirms-and-updates ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed)
    (with-temp-buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id 11)
      (setq-local
       bitbucket-devops-pull-requests-ui--details-pull-request
       '((reviewers
          . (((display_name . "Ada") (uuid . "{ada}"))
             ((display_name . "Grace") (account_id . "account-grace"))))))
      (let ((selection
             (caar (bitbucket-devops-pull-requests-ui--reviewer-candidates))))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _args) t))
                  ((symbol-function 'bitbucket-devops-pull-requests-rest-update)
                   (lambda (_context _pull-request-id body _callback)
                     (setq observed body))))
          (bitbucket-devops-pull-requests-ui-remove-reviewer selection)
          (should
           (equal
            observed
            '((reviewers
               . [((account_id . "account-grace"))])))))))))

(provide 'bitbucket-devops-pull-requests-ui-test)
;;; bitbucket-devops-pull-requests-ui-test.el ends here
