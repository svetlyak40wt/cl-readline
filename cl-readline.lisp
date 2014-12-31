;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp -*-
;;;
;;; cl-readline, bindings to GNU Readline library.
;;;
;;; Copyright (c) 2014 Mark Karpov
;;;
;;; This program is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by the
;;; Free Software Foundation, either version 3 of the License, or (at your
;;; option) any later version.
;;;
;;; This program is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
;;; Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License along
;;; with this program. If not, see <http://www.gnu.org/licenses/>.

(cl:defpackage :cl-readline
  (:nicknames  :rl)
  (:use        #:common-lisp
               #:alexandria
               #:cffi)
  (:export
   ;; Readline Variables
   #:*line-buffer*
   #:*point*
   #:*end*
   #:*mark*
   #:*done*
   #:+prompt+
   #:*display-prompt*
   #:+library-version+
   #:+readline-version+
   #:+gnu-readline-p+
   #:*terminal-name*
   #:*readline-name*
   #:*prefer-env-winsize*
   #:+executing-keymap+
   #:+binding-keymap+
   #:+executing-macro+
   #:+executing-key+
   #:+executing-keyseq+
   #:+key-sequence-length+
   #:+readline-state+
   #:+explicit-arg+
   #:+numeric-arg+
   #:+editing-mode+
   #:+emacs-std-keymap+
   #:+emacs-meta-keymap+
   #:+emacs-ctlx-keymap+
   #:+vi-insertion-keymap+
   #:+vi-movement-keymap+
   ;; Basic Functionality
   #:readline
   #:add-defun
   ;; Hooks and Custom Functions
   #:register-hook
   #:register-function
   ;; Work with Keymaps
   #:make-keymap
   #:copy-keymap
   #:free-keymap
   #:get-keymap
   #:set-keymap
   #:get-keymap-by-name
   #:get-keymap-name
   #:with-new-keymap
   ;; Binding keys
   #:bind-key
   #:unbind-key
   #:unbind-command
   #:bind-keyseq
   #:parse-and-bind
   #:read-init-file
   ;; Associating Function Names and Bindings
   #:function-dumper
   #:list-funmap-names
   #:funmap-names
   #:add-funmap-entry
   ;; Allowing Undoing
   #:undo-group
   #:add-undo
   #:free-undo-list
   #:do-undo
   #:modifying
   ;; Redisplay
   #:redisplay
   #:forced-update-display
   #:on-new-line
   #:reset-line-state
   #:crlf
   #:show-char
   #:with-message
   #:set-prompt
   ;; Modifying Text
   #:insert-text
   #:delete-text
   #:kill-text
   ;; Character Input
   #:read-key
   #:stuff-char
   #:execute-next
   #:clear-pending-input
   #:set-keyboard-input-timeout
   ;; Terminal Management
   #:prep-terminal
   #:deprep-terminal
   #:tty-set-default-bindings
   #:tty-unset-default-bindings
   #:reset-terminal
   ;; Utility Functions
   #:replace-line
   #:extend-line-buffer
   #:initialize
   #:ding
   ;; Miscelaneous Functions
   #:macro-dumper
   #:variable-bind
   #:variable-value
   #:variable-dumper
   #:set-paren-blink-timeout
   #:clear-history
   ;; Signal Handling
   
   ;; Custom Completion
   ))

(in-package #:cl-readline)

(define-foreign-library readline
  (:unix (:or "libreadline.so.6.3"
              "libreadline.so.6"
              "libreadline.so"))
  (t     (:default "libreadline")))

(use-foreign-library readline)

(defvar +states+
  '(:initializing  ; 0x0000001 initializing
    :initialized   ; 0x0000002 initialization done
    :termprepped   ; 0x0000004 terminal is prepped
    :readcmd       ; 0x0000008 reading a command key
    :metanext      ; 0x0000010 reading input after ESC
    :dispatching   ; 0x0000020 dispatching to a command
    :moreinput     ; 0x0000040 reading more input in a command function
    :isearch       ; 0x0000080 doing incremental search
    :nsearch       ; 0x0000100 doing non-incremental search
    :search        ; 0x0000200 doing a history search
    :numericarg    ; 0x0000400 reading numeric argument
    :macroinput    ; 0x0000800 getting input from a macro
    :macrodef      ; 0x0001000 defining keyboard macro
    :overwrite     ; 0x0002000 overwrite mode
    :completing    ; 0x0004000 doing completion
    :sighandler    ; 0x0008000 in readline sighandler
    :undoing       ; 0x0010000 doing an undo
    :inputpending  ; 0x0020000 rl_execute_next called
    :ttycsaved     ; 0x0040000 tty special chars saved
    :callback      ; 0x0080000 using the callback interface
    :vimotion      ; 0x0100000 reading vi motion arg
    :multikey      ; 0x0200000 reading multiple-key command
    :vicmdonce     ; 0x0400000 entered vi command mode at least once
    :readisplaying ; 0x0800000 updating terminal display
    :done)         ; 0x1000000 done; accepted line
  "Possible state values for +RL-READLINE-STATE+.")

(defvar +editing-modes+
  '(:vi            ; vi mode is active
    :emacs)        ; Emacs mode is active
  "Value denoting Readline's current editing mode.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                        ;;
;;                                Helpers                                 ;;
;;                                                                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun decode-version (version)
  "Transform VERSION into two values representing major and minor numbers of
Readline library version."
  (values (ldb (byte 8 8) version)
          (ldb (byte 8 0) version)))

(defun decode-state (state)
  "Transform Readline STATE into corresponding keyword."
  (mapcan (lambda (index keyword)
            (when (logbitp index state)
              (list keyword)))
          (iota (length +states+))
          +states+))

(defun decode-editing-mode (mode)
  "Transform C int into a keyword representing current editing mode."
  (or (nth mode +editing-modes+)
      :unknown))

(defmacro produce-callback (function return-type &optional func-arg-list)
  "Return pointer to callback that calls FUNCTION."
  (let ((gensymed-list (mapcar (lambda (x) (list (gensym) x))
                               func-arg-list)))
    (with-gensyms (temp)
      `(if ,function
           (progn
             (defcallback ,temp ,return-type ,gensymed-list
               (funcall ,function ,@(mapcar #'car gensymed-list)))
             (get-callback ',temp))
           (null-pointer)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                        ;;
;;                      Foreign Structures and Types                      ;;
;;                                                                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defctype int-char
    (:wrapper :int
              :from-c code-char
              :to-c   char-code)
  "This wrapper performs conversion between C int and Lisp character.")

(defctype version
    (:wrapper :int
              :from-c decode-version)
  "This wrapper performs conversion between raw C int representing version
of Readline library and Lisp values.")

(defctype state
    (:wrapper :int
              :from-c decode-state)
  "This wrapper performs conversion between raw C int representing state of
Readline and readable Lisp keyword.")

(defctype editing-mode
    (:wrapper :int
              :from-c decode-editing-mode)
  "This wrapper performs conversion between C int and a keyword representing
current editing mode.")

(defcenum undo-code
  :undo-delete
  :undo-insert
  :undo-begin
  :undo-end)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                        ;;
;;                           Readline Variables                           ;;
;;                                                                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Descriptions here from official documentation for GNU Readline, the
;; documentation can be found at
;; http://cnswww.cns.cwru.edu/php/chet/readline/readline.html

(defcvar ("rl_line_buffer" *line-buffer*) :string
  "This is the line gathered so far. You are welcome to modify the contents
of the line, but remember about undoing. The function EXTEND-LINE-BUFFER is
available to increase the memory allocated to *LINE-BUFFER*.")

(defcvar ("rl_point" *point*) :int
  "The offset of the current cursor position in *LINE-BUFFER* (the point).")

(defcvar ("rl_end" *end*) :int
  "The number of characters present in *LINE-BUFFER*. When *POINT* is at the
end of the line, *POINT* and *END* are equal.")

(defcvar ("rl_mark" *mark*) :int
  "The mark (saved position) in the current line. If set, the mark and point
define a region.")

(defcvar ("rl_done" *done*) :boolean
  "Setting this to a non-NIL value causes Readline to return the current
line immediately.")

(defcvar ("rl_num_chars_to_read" *num-chars-to-read*) :int
  "Setting this to a positive value before calling READLINE causes Readline
to return after accepting that many characters, rather than reading up to a
character bound to accept-line.")

(defcvar ("rl_pending_input" *pending-input*) :int ;; not used
  "Setting this to a value makes it the next keystroke read. This is a way
to stuff a single character into the input stream.")

(defcvar ("rl_dispatching" *dispatching*) :boolean
  ;; TODO: use as arg of function called by a cmd
  "Set to a non-NIL value if a function is being called from a key binding;
NIL otherwise. Application functions can test this to discover whether they
were called directly or by Readline's dispatching mechanism. ")

(defcvar ("rl_erase_empty_line" *erase-empty-line*) :boolean
  "Setting this to a non-NIL value causes Readline to completely erase the
current line, including any prompt, any time a newline is typed as the only
character on an otherwise-empty line. The cursor is moved to the beginning
of the newly-blank line.")

(defcvar ("rl_prompt" +prompt+ :read-only t) :string
  "The prompt Readline uses. This is set from the argument to READLINE,
and should not be assigned to directly. The SET-PROMPT function may be used
to modify the prompt string after calling READLINE.")

(defcvar ("rl_display_prompt" *display-prompt*) :string
  "The string displayed as the prompt. This is usually identical to
+PROMPT+, but may be changed temporarily by functions that use the prompt
string as a message area, such as incremental search.")

(defcvar ("rl_already_prompted" *already-prompted*) :boolean
  "If an application wishes to display the prompt itself, rather than have
Readline do it the first time READLINE is called, it should set this
variable to a non-NIL value after displaying the prompt. The prompt must
also be passed as the argument to READLINE so the redisplay functions can
update the display properly. The calling application is responsible for
managing the value; Readline never sets it.")

(defcvar ("rl_library_version" +library-version+ :read-only t) :string
  "The version number of this revision of the library.")

(defcvar ("rl_readline_version" +readline-version+ :read-only t) version
  "Major and minor version numbers of Readline library.")

(defcvar ("rl_gnu_readline_p" +gnu-readline-p+ :read-only t) :boolean
  "Always evaluated to T, denoting that this is GNU readline rather than
some emulation.")

(defcvar ("rl_terminal_name" *terminal-name*) :string
  "The terminal type, used for initialization. If not set by the
application, Readline sets this to the value of the TERM environment
variable the first time it is called.")

(defcvar ("rl_readline_name" *readline-name*) :string
  "This symbol-macro should be set to a unique name by each application
using Readline. The value allows conditional parsing of the inputrc file.")

(defcvar ("rl_instream" *instream*) :pointer ;; not used
  "The stdio stream from which Readline reads input. If NULL, Readline
defaults to stdin.")

(defcvar ("rl_outstream" *outstream*) :pointer
  "The stdio stream to which Readline performs output. If NULL, Readline
defaults to stdout.")

(defcvar ("rl_prefer_env_winsize" *prefer-env-winsize*) :boolean
  "If non-NIL, Readline gives values found in the LINES and COLUMNS
environment variables greater precedence than values fetched from the kernel
when computing the screen dimensions.")

(defcvar ("rl_last_func" *last-func*) :pointer ;; not used
  "The address of the last command function Readline executed. May be used
to test whether or not a function is being executed twice in succession, for
example.")

(defcvar ("rl_startup_hook" *startup-hook*) :pointer
  "If non-zero, this is the address of a function to call just before
readline prints the first prompt.")

(defcvar ("rl_pre_input_hook" *pre-input-hook*) :pointer
  "If non-zero, this is the address of a function to call after the first
prompt has been printed and just before readline starts reading input
characters.")

(defcvar ("rl_event_hook" *event-hook*) :pointer
  "If non-zero, this is the address of a function to call periodically when
Readline is waiting for terminal input. By default, this will be called at
most ten times a second if there is no keyboard input.")

(defcvar ("rl_getc_function" *getc-function*) :pointer
  "If non-zero, Readline will call indirectly through this pointer to get a
character from the input stream. By default, it is set to rl_getc, the
default Readline character input function (see section 2.4.8 Character
Input). In general, an application that sets rl_getc_function should
consider setting rl_input_available_hook as well.")

(defcvar ("rl_signal_event_hook" *signal-event-hook*) :pointer
  "If non-zero, this is the address of a function to call if a read system
call is interrupted when Readline is reading terminal input.")

(defcvar ("rl_input_available_hook" *input-available-hook*) :pointer
  "If non-zero, Readline will use this function's return value when it needs
to determine whether or not there is available input on the current input
source.")

(defcvar ("rl_redisplay_function" *redisplay-function*) :pointer
  "If non-zero, Readline will call indirectly through this pointer to update
the display with the current contents of the editing buffer. By default, it
is set to rl_redisplay, the default Readline redisplay function (see section
2.4.6 Redisplay).")

(defcvar ("rl_prep_term_function" *prep-term-function*) :pointer
  "If non-zero, Readline will call indirectly through this pointer to
initialize the terminal. The function takes a single argument, an int flag
that says whether or not to use eight-bit characters. By default, this is
set to rl_prep_terminal (see section 2.4.9 Terminal Management).")

(defcvar ("rl_deprep_term_function" *deprep-term-function*) :pointer
  "If non-zero, Readline will call indirectly through this pointer to reset
the terminal. This function should undo the effects of
rl_prep_term_function. By default, this is set to rl_deprep_terminal (see
section 2.4.9 Terminal Management).")

(defcvar ("rl_executing_keymap" +executing-keymap+ :read-only t) :pointer
  "This variable is evaluated to the keymap in which the currently executing
Readline function was found.")

(defcvar ("rl_binding_keymap" +binding-keymap+ :read-only t) :pointer
  "This variable is evaluated to the keymap in which the last key binding
occurred.")

(defcvar ("rl_executing_macro" +executing-macro+ :read-only t) :string
  "This variable is evaluated to the text of any currently-executing
macro.")

(defcvar ("rl_executing_key" +executing-key+ :read-only t) int-char
  "The key that caused the dispatch to the currently-executing Readline
function.")

(defcvar ("rl_executing_keyseq" +executing-keyseq+ :read-only t) :string
  "The full key sequence that caused the dispatch to the currently-executing
Readline function.")

(defcvar ("rl_key_sequence_length" +key-sequence-length :read-only t) :int
  "The number of characters in +EXECUTING-KEYSEQ+.")

(defcvar ("rl_readline_state" +readline-state+ :read-only t) state
  "This symbol macro is evaluated to a list containing keywords that denote
state of Readline.")

(defcvar ("rl_explicit_arg" +explicit-arg+ :read-only t) :boolean
  "Evaluated to T if an explicit numeric argument was specified by the
user. Only valid in a bindable command function.")

(defcvar ("rl_numeric_arg" +numeric-arg+ :read-only t) :int
  "Evaluated to the value of any numeric argument explicitly specified by
the user before executing the current Readline function. Only valid in a
bindable command function.")

(defcvar ("rl_editing_mode" +editing-mode+ :read-only t) editing-mode
  "Evaluated to keyword denoting actual editing mode: :EMACS, :VI,
or :UNKNOWN.")

(defcvar ("emacs_standard_keymap" +emacs-std-keymap+ :read-only t) :pointer
  "Emacs standard keymap - default keymap of Readline.")

(defcvar ("emacs_meta_keymap" +emacs-meta-keymap+ :read-only t) :pointer
  "Emacs meta keymap.")

(defcvar ("emacs_ctlx_keymap" +emacs-ctlx-keymap+ :read-only t) :pointer
  "Emacs Ctlx keymap.")

(defcvar ("vi_insertion_keymap" +vi-insertion-keymap+ :read-only t) :pointer
  "Vi insertion keymap.")

(defcvar ("vi_movement_keymap" +vi-movement-keymap+ :read-only t) :pointer
  "Vi movement keymap.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                        ;;
;;                          Basic Functionality                           ;;
;;                                                                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun readline (&key
                   prompt
                   already-prompted
                   num-chars
                   erase-empty-line
                   add-history)
  "Get a line from user with editing. If PROMPT supplied (and it's a string
designator), it will be printed before reading of input. Non-NIL value of
ALREADY-PROMPTED will tell Readline that the application has printed prompt
already. However PROMPT must be supplied in this case too, so redisplay
functions can update the display properly. If NUM-CHARS argument is a
positive number, Readline will return after accepting that many
characters. If ERASE-EMPTY-LINE is not NIL, READLINE will completely erase
the current line, including any prompt, any time a newline is typed as the
only character on an otherwise-empty line. The cursor is moved to the
beginning of the newly-blank line. If ADD-HISTORY supplied and its value is
not NIL, user's input will be added to history. However, blank lines don't
get into history anyway. Return value on success is the actual string and
NIL on failure."
  (setf *already-prompted*  already-prompted
        *num-chars-to-read* (if (and (integerp num-chars)
                                     (plusp    num-chars))
                                num-chars
                                0)
        *erase-empty-line* erase-empty-line)
  (let* ((prompt (if (and (not (null prompt))
                          (typep prompt 'string-designator))
                     (string prompt)
                     ""))
         (ptr (foreign-funcall "readline"
                               :string prompt
                               :pointer)))
    (when (and (pointerp ptr)
               (not (null-pointer-p ptr)))
      (unwind-protect
           (let ((str (foreign-string-to-lisp ptr)))
             (when (and add-history
                        (not (emptyp str)))
               (foreign-funcall "add_history"
                                :string str
                                :void))
             str)
        (foreign-funcall "free"
                         :pointer ptr
                         :void)))))

(defun ensure-initialization ()
  "Makes sure that Readline is initialized. If it's not initialized yet,
initializes it."
  (unless (find :initialized +readline-state+)
    (initialize)))

(defun add-defun (name function &optional key)
  "Add NAME to the list of named functions. Make FUNCTION be the function
that gets called. If KEY is not NIL and it's a character, then bind it to
function using BIND-KEY. FUNCTION must be able to take at least two
arguments: integer representing its argument and character representing key
that has invoked it."
  (ensure-initialization)
  (foreign-funcall "rl_add_defun"
                   :string name
                   :pointer (produce-callback function
                                              :boolean
                                              (:int int-char))
                   :int (if key (char-code key) -1)))

(defmacro with-possible-redirection (filename append &body body)
  "If FILENAME is not NIL, tries to create C file with name FILENAME,
temporarily reassign *OUTSTREAM* to pointer to this file, perform BODY, then
close the file and assign *OUTSTREAM* to the old value. If APPEND is not
NIL, output will be appended to the file. Return NIL of success and T on
failure."
  (with-gensyms (temp-outstream file-pointer body-fnc)
    `(flet ((,body-fnc ()
              ,@body))
       (if ,filename
           (let ((,temp-outstream *outstream*)
                 (,file-pointer (foreign-funcall "fopen"
                                                 :string ,filename
                                                 :string (if ,append "a" "w")
                                                 :pointer)))
             (if ,file-pointer
                 (unwind-protect
                      (progn
                        (setf *outstream* ,file-pointer)
                        (,body-fnc))
                   (progn
                     (foreign-funcall "fclose"
                                      :pointer ,file-pointer
                                      :boolean)
                     (setf *outstream* ,temp-outstream)))
                 t)
             (,body-fnc))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                        ;;
;;                       Hooks and Custom Functions                       ;;
;;                                                                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun register-hook (hook function)
  "Register a hook. FUNCTION must be a function that takes no arguments and
returns NIL on success and T on failure. If FUNCTION is NIL, hook will be
removed. HOOK should be a keyword, one of the following:

:STARTUP hook is called just before READLINE prints the prompt.

:PRE-INPUT hook is called after prompt has been printed and just before
READLINE starts reading input characters.

:EVENT hook is called periodically when waiting for terminal input. By
default, this will be called at most ten times a second if there is no
keyboard input.

:SIGNAL hook is called when a read system call is interrupted when
READLINE is reading terminal input.

:INPUTP hook is called when Readline need to determine whether or not there
is available input on the current input source. If FUNCTION returns NIL, it
means that there is no available input.

Other values of HOOK will be ignored."
  (let ((cb (produce-callback function :boolean)))
    (cond ((eql :startup   hook) (setf *startup-hook*         cb))
          ((eql :pre-input hook) (setf *pre-input-hook*       cb))
          ((eql :event     hook) (setf *event-hook*           cb))
          ((eql :signal    hook) (setf *signal-event-hook*    cb))
          ((eql :inputp    hook) (setf *input-available-hook* cb))))
  nil)

(defun register-function (func function)
  "Register a function. FUNCTION must be a function, if FUNCTION is NIL,
result is unpredictable. FUNC should be a keyword, one of the following:

:GETC function is used to get a character from the input stream, thus
FUNCTION should take pointer to C stream and return a character if this
function is desired to be registered. In general, an application that
registers :GETC function should consider registering :INPUTP hook as
well (see REGISTER-HOOK).

:REDISPLAY function is used to update the display with the current contents
of the editing buffer, thus FUNCTION should take no arguments and return NIL
on success and non-NIL of failure. By default, it is set to REDISPLAY, the
default Readline redisplay function.

:PREP-TERM function is used to initialize the terminal, so FUNCTION must be
able to take at least one argument, a flag that says whether or not to use
eight-bit characters. By default, PREP-TERMINAL is used.

:DEPREP-TERM function is used to reset the terminal. This function should
undo the effects of :PREP-TERM function.

Other values of FUNC will be ignored."
  (cond ((eql :getc func)
         (setf *getc-function*
               (produce-callback function int-char (:pointer))))
        ((eql :redisplay func)
         (setf *redisplay-function*
               (produce-callback function :void)))
        ((eql :prep-term func)
         (setf *prep-term-function*
               (produce-callback function :void (:boolean))))
        ((eql :deprep-term func)
         (setf *deprep-term-function*
               (produce-callback function :void))))
  nil)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                        ;;
;;                           Work with Keymaps                            ;;
;;                                                                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun make-keymap (&optional bare)
  "Return a new keymap with self-inserting printing characters, the
lowercase Meta characters bound to run their equivalents, and the Meta
digits bound to produce numeric arguments. If BARE is supplied and it's not
NIL, empty keymap will be returned."
  (if bare
      (foreign-funcall "rl_make_bare_keymap"
                       :pointer)
      (foreign-funcall "rl_make_keymap"
                       :pointer)))

(defcfun ("rl_copy_keymap" copy-keymap) :pointer
  "Return a new keymap which is a copy of map.")

(defcfun ("rl_free_keymap" free-keymap) :void
  "Free all storage associated with keymap."
  (keymap :pointer))

(defcfun ("rl_get_keymap" get-keymap) :pointer
  "Returns currently active keymap.")

(defcfun ("rl_set_keymap" set-keymap) :void
  "Makes KEYMAP the currently active keymap."
  (keymap :pointer))

(defcfun ("rl_get_keymap_by_name" get-keymap-by-name) :pointer
  "Return the keymap matching NAME. NAME is one which would be supplied in a
set keymap inputrc line.")

(defcfun ("rl_get_keymap_name" get-keymap-name) :string
  "Return the name matching KEYMAP. Name is one which would be supplied in a
set keymap inputrc line."
  (keymap :pointer))

(defmacro with-new-keymap (form &body body)
  "Create new keymap evaluating FORM, then free it when control flow leaves
BODY. MAKE-KEYMAP and COPY-KEYMAP can be used to produce new keymap."
  (with-gensyms (keymap)
    `(let ((,keymap ,form))
       ,@body
       (free-keymap ,keymap))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                        ;;
;;                              Binding Keys                              ;;
;;                                                                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun bind-key (key function &key keymap if-unbound)
  "Binds KEY to FUNCTION in the currently active keymap. If KEYMAP argument
supplied, binding takes place in specified KEYMAP. If IF-UNBOUND is supplied
and it's not NIL, KEY will be bound to FUNCTION only if it's not already
bound."
  (let ((cb (produce-callback function :boolean (:int int-char))))
    (cond ((and keymap if-unbound)
           (foreign-funcall "rl_bind_key_if_unbound_in_map"
                            int-char key
                            :pointer cb
                            :pointer keymap
                            :boolean))
          (keymap
           (foreign-funcall "rl_bind_key_in_map"
                            int-char key
                            :pointer cb
                            :pointer keymap
                            :boolean))
          (if-unbound
           (foreign-funcall "rl_bind_key_if_unbound"
                            int-char key
                            :pointer cb
                            :boolean))
          (t
           (foreign-funcall "rl_bind_key"
                            int-char key
                            :pointer cb
                            :boolean)))))

(defun unbind-key (key &optional keymap)
  "Unbind KEY in KEYMAP. If KEYMAP is not supplied or it's NIL, KEY will be
unbound in currently active keymap. The function returns NIL on success and
T on failure."
  (if keymap
      (foreign-funcall "rl_unbind_key_in_map"
                       int-char key
                       :pointer keymap
                       :boolean)
      (foreign-funcall "rl_unbind_key"
                       int-char key
                       :boolean)))

;; rl_unbind_function_in_map

(defcfun ("rl_unbind_command_in_map" unbind-command) :boolean
  "Unbind all keys that are bound to COMMAND in KEYMAP."
  (command :string)
  (keymap  :pointer))

(defun bind-keyseq (keyseq function &key keymap if-unbound)
  "Bind the key sequence represented by the string KEYSEQ to the function
FUNCTION, beginning in the current keymap. This makes new keymaps as
necessary. If KEYMAP supplied and it's not NIL, initial bindings are
performed in KEYMAP. If IF-UNBOUND is supplied and it's not NIL, KEYSEQ will
be bound to FUNCTION only if it's not already bound. The return value is T
if KEYSEQ is invalid."
  (let ((cb (produce-callback function :boolean (:int int-char))))
    (cond ((and keymap if-unbound)
           (foreign-funcall "rl_bind_keyseq_if_unbound_in_map"
                            :string  keyseq
                            :pointer cb
                            :pointer keymap
                            :boolean))
          (keymap
           (foreign-funcall "rl_bind_keyseq_in_map"
                            :string  keyseq
                            :pointer cb
                            :pointer keymap
                            :boolean))
          (if-unbound
           (foreign-funcall "rl_bind_keyseq_if_unbound"
                            :string  keyseq
                            :pointer cb
                            :boolean))
          (t
           (foreign-funcall "rl_bind_keyseq"
                            :string  keyseq
                            :pointer cb
                            :boolean)))))

(defcfun ("rl_parse_and_bind" parse-and-bind) :boolean
  "Parse LINE as if it had been read from the inputrc file and perform any
key bindings and variable assignments found."
  (line :string))

(defcfun ("rl_read_init_file" read-init-file) :boolean
  "Read keybindings and variable assignments from FILENAME."
  (filename :string))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                        ;;
;;                Associating Function Names and Bindings                 ;;
;;                                                                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; rl_named_function
;; rl_function_of_keyseq
;; rl_invoking_keyseqs
;; rl_invoking_keyseqs_in_map

(defun function-dumper (readable &optional filename append)
  "Print the Readline function names and the key sequences currently bound
to them to stdout. If readable is non-NIL, the list is formatted in such a
way that it can be made part of an inputrc file and re-read. If FILENAME is
supplied and it's a string or path, output will be redirected to the
file. APPEND allows to append text to the file instead of overwriting it."
  (ensure-initialization)
  (with-possible-redirection filename append
    (foreign-funcall "rl_function_dumper"
                     :boolean readable
                     :void)))

(defun list-funmap-names (&optional filename append)
  "Print the names of all bindable Readline functions to stdout. If FILENAME
is supplied and it's a string or path, output will be redirected to the
file. APPEND allows append text to the file instead of overwriting it."
  (ensure-initialization)
  (with-possible-redirection filename append
    (foreign-funcall "rl_list_funmap_names"
                     :void)))

(defun funmap-names ()
  "Return a list of known function names. The list is sorted."
  (ensure-initialization)
  (let ((ptr (foreign-funcall "rl_funmap_names"
                              :pointer))
        result)
    (when ptr
      (unwind-protect
           (do ((i 0 (1+ i)))
               ((null-pointer-p (mem-aref ptr :pointer i))
                (reverse result))
             (push (foreign-string-to-lisp (mem-aref ptr :pointer i))
                   result))
        (foreign-funcall "free"
                         :pointer ptr
                         :void)))))

(defun add-funmap-entry (name function)
  "Add NAME to the list of bindable Readline command names, and make
FUNCTION the function to be called when name is invoked."
  (foreign-funcall "rl_add_funmap_entry"
                   :string name
                   :pointer (produce-callback function
                                              :boolean
                                              (:int int-char))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                        ;;
;;                            Allowing Undoing                            ;;
;;                                                                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defmacro undo-group (&body body)
  "All insertion and deletion inside this macro will be grouped together
into one undo operation."
  `(progn
     (foreign-funcall "rl_begin_undo_group" :boolean)
     ,@body
     (foreign-funcall "rl_end_undo_group" :boolean)))

(defcfun ("rl_add_undo" add-undo) :void
  "Remember how to undo an event (according to WHAT). The affected text runs
from START to END, and encompasses TEXT. Possible values of WHAT
include: :UNDO-DELETE, :UNDO-INSERT, :UNDO-BEGIN, and :UNDO-END."
  (what  undo-code)
  (start :int)
  (end   :int)
  (text  :string))

(defcfun ("rl_free_undo_list" free-undo-list) :void
  "Free the existing undo list.")

(defcfun ("rl_do_undo" do-undo) :boolean
  "Undo the first thing on the undo list. Returns NIL if there was nothing
to undo, T if something was undone.")

(defcfun ("rl_modifying" modifying) :boolean
  "Tell Readline to save the text between START and END as a single undo
unit. It is assumed that you will subsequently modify that text."
  (start :int)
  (end   :int))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                        ;;
;;                               Redisplay                                ;;
;;                                                                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defcfun ("rl_redisplay" redisplay) :void
  "Change what's displayed on the screen to reflect the current contents of
*LINE-BUFFER*.")

(defcfun ("rl_forced_update_display" forced-update-display) :boolean
  "Force the line to be updated and redisplayed, whether or not Readline
thinks the screen display is correct.")

(defun on-new-line (&optional with-prompt)
  "Tell the update functions that we have moved onto a new (empty) line,
usually after outputting a newline. When WITH-PROMPT is T, Readline will
think that prompt is already displayed. This could be used by applications
that want to output the prompt string themselves, but still need Readline to
know the prompt string length for redisplay. This should be used together
with :ALREADY-PROMPTED keyword argument of READLINE."
  (if with-prompt
      (foreign-funcall "rl_on_new_line_with_prompt" :boolean)
      (foreign-funcall "rl_on_new_line" :boolean)))

(defcfun ("rl_reset_line_state" reset-line-state) :boolean
  "Reset the display state to a clean state and redisplay the current line
starting on a new line.")

(defcfun ("rl_crlf" crlf) :boolean
  "Move the cursor to the start of the next screen line.")

(defcfun ("rl_show_char" show-char) :boolean
  "Display character CHAR on outstream. If Readline has not been set to
display meta characters directly, this will convert meta characters to a
meta-prefixed key sequence. This is intended for use by applications which
wish to do their own redisplay."
  (char int-char))

(defmacro with-message (message save-prompt &body body)
  "Show message MESSAGE in the echo area while executing BODY. If
SAVE-PROMPT is not NIL, save prompt before showing the message and restore
it before clearing the message."
  `(progn
     (when ,save-prompt
       (foreign-funcall "rl_save_prompt" :void))
     (foreign-funcall "rl_message"
                      :string ,message
                      :boolean)
     ,@body
     (when ,save-prompt
       (foreign-funcall "rl_restore_prompt" :void))
     (foreign-funcall "rl_clear_message" :boolean)))

(defcfun ("rl_set_prompt" set-prompt) :boolean
  "Make Readline use prompt for subsequent redisplay. This calls
EXPAND-PROMPT to expand the prompt and sets PROMPT to the result."
  (prompt :string))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                        ;;
;;                             Modifying Text                             ;;
;;                                                                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defcfun ("rl_insert_text" insert-text) :int
  "Insert TEXT into the line at the current cursor position. Returns the
number of characters inserted."
  (text :string))

(defcfun ("rl_delete_text" delete-text) :int
  "Delete the text between START and END in the current line. Returns the
number of characters deleted."
  (start :int)
  (end   :int))

(defcfun ("rl_kill_text" kill-text) :boolean
  "Copy the text between START and END in the current line to the kill ring,
appending or prepending to the last kill if the last command was a kill
command. The text is deleted. If START is less than END, the text is
appended, otherwise prepended. If the last command was not a kill, a new
kill ring slot is used."
  (start :int)
  (end   :int))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                        ;;
;;                            Character Input                             ;;
;;                                                                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defcfun ("rl_read_key" read-key) int-char
  "Return the next character available from Readline's current input
stream.")

(defcfun ("rl_stuff_char" stuff-char) :boolean
  "Insert CHAR into the Readline input stream. It will be 'read' before
Readline attempts to read characters from the terminal with READ-KEY. Up to
512 characters may be pushed back. STUFF-CHAR returns T if the character was
successfully inserted; NIL otherwise."
  (char int-char))

(defcfun ("rl_execute_next" execute-next) :boolean
  "Make CHAR be the next command to be executed when READ-KEY is
called."
  (char int-char))

(defcfun ("rl_clear_pending_input" clear-pending-input) :boolean
  "Negate the effect of any previous call to EXECUTE-NEXT. This works only
if the pending input has not already been read with READ-KEY.")

(defcfun ("rl_set_keyboard_input_timeout" set-keyboard-input-timeout) :int
  "While waiting for keyboard input in READ-KEY, Readline will wait for U
microseconds for input before calling any function assigned to EVENT-HOOK. U
must be greater than or equal to zero (a zero-length timeout is equivalent
to a poll). The default waiting period is one-tenth of a second. Returns the
old timeout value."
  (u :int))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                        ;;
;;                          Terminal Management                           ;;
;;                                                                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defcfun ("rl_prep_terminal" prep-terminal) :void
  "Modify the terminal settings for Readline's use, so READLINE can read a
single character at a time from the keyboard. The EIGHT-BIT-INPUT argument
should be non-NIL if Readline should read eight-bit input."
  (eight-bit-input :boolean))

(defcfun ("rl_deprep_terminal" deprep-terminal) :void
  "Undo the effects of PREP-TERMINAL, leaving the terminal in the state in
which it was before the most recent call to PREP-TERMINAL.")

(defun tty-set-default-bindings (keymap)
  "Read the operating system's terminal editing characters (as would be
displayed by stty) to their Readline equivalents. The bindings are performed
in KEYMAP."
  (ensure-initialization)
  (foreign-funcall "rl_tty_set_default_bindings"
                   :pointer keymap
                   :void))

(defcfun ("rl_tty_unset_default_bindings" tty-unset-default-bindings) :void
  "Reset the bindings manipulated by TTY-SET-DEFAULT-BINDINGS so that the
terminal editing characters are bound to INSERT. The bindings are performed
in KEYMAP."
  (keymap :pointer))

(defcfun ("rl_reset_terminal" reset-terminal) :boolean
  "Reinitialize Readline's idea of the terminal settings using terminal_name
as the terminal type (e.g., vt100)."
  (terminal :string))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                        ;;
;;                           Utility Functions                            ;;
;;                                                                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defcfun ("rl_replace_line" replace-line) :void
  "Replace the contents of *LINE-BUFFER* with TEXT. The point and mark are
preserved, if possible. If CLEAR-UNDO is non-zero, the undo list associated
with the current line is cleared."
  (text       :string)
  (clear-undo :boolean))

(defcfun ("rl_extend_line_buffer" extend-line-buffer) :void
  "Ensure that line buffer has enough space to hold LEN characters,
possibly reallocating it if necessary."
  (len :int))

(defcfun ("rl_initialize" initialize) :boolean
  "Initialize or re-initialize Readline's internal state. It's not strictly
necessary to call this; READLINE calls it before reading any input.")

(defcfun ("rl_ding" ding) :boolean
  "Ring the terminal bell, obeying the setting of bell-style.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                        ;;
;;                         Miscelaneous Functions                         ;;
;;                                                                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun macro-dumper (readable &optional filename append)
  "Print the key sequences bound to macros and their values, using the
current keymap to stdout. If READABLE is non-NIL, the list is formatted in
such a way that it can be made part of an inputrc file and re-read. If
filename is supplied and it's a string or path, output will be redirected to
the file. APPEND allows to append text to the file instead of overwriting
it."
  (ensure-initialization)
  (with-possible-redirection filename append
    (foreign-funcall "rl_macro_dumper"
                     :boolean readable
                     :void)))

(defun variable-bind (variable value)
  "Make the Readline variable VARIABLE have VALUE. This behaves as if the
readline command 'set variable value' had been executed in an inputrc file."
  (ensure-initialization)
  (foreign-funcall "rl_variable_bind"
                   :string variable
                   :string value
                   :boolean))

(defun variable-value (variable)
  "Return a string representing the value of the Readline variable
VARIABLE. For boolean variables, this string is either 'on' or 'off'."
  (ensure-initialization)
  (foreign-funcall "rl_variable_value"
                   :string variable
                   :string))

(defun variable-dumper (readable &optional filename append)
  "Print the readline variable names and their current values to stdout. If
readable is not NIL, the list is formatted in such a way that it can be made
part of an inputrc file and re-read. If FILENAME is supplied and it's a
string or path, output will be redirected to the file. APPEND allows to
append text to the file instead of overwriting it."
  (ensure-initialization)
  (with-possible-redirection filename append
    (foreign-funcall "rl_variable_dumper"
                     :boolean readable
                     :void)))

(defcfun ("rl_set_paren_blink_timeout" set-paren-blink-timeout) :int
  "Set the time interval (in microseconds) that Readline waits when showing
a balancing character when blink-matching-paren has been enabled. The
function returns previous value of the parameter."
  (micros :int))

(defcfun ("rl_clear_history" clear-history) :void
  "Clear the history list by deleting all of the entries.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                        ;;
;;                            Signal Handling                             ;;
;;                                                                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; ???

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                        ;;
;;                           Custom Completion                            ;;
;;                                                                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; custom completers

;; rl_complete
;; rl_completion_entry_function <- pointer to function that produces completions

;; ... see more in the manual.

;; good interface would be something like this:

;; (rl-use-completion <function or nil> completion-type)

;; function should take a string to complete and return list of completions
