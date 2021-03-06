#!/usr/bin/env roseus

;; forostep-controller.l
(ros::roseus-add-msgs "std_msgs")
(ros::roseus-add-msgs "jsk_footstep_msgs")
(ros::roseus-add-msgs "jsk_rviz_plugins")
(ros::roseus-add-srvs "jsk_footstep_controller")
(ros::roseus-add-msgs "jsk_footstep_controller")

(defvar *all-the-results* nil)

(setq *realp* t)
(setq *wait-contact-state* t)
;;(setq *wait-contact-state* nil)
(setq *check-breakpoint* t)
;;(setq *realp* nil)
;; :standing
;; :plane
;; :climing-up
(setq *walking-state* :standing)
(setq *prev-footstep* nil)
(setq *footstep-list* nil)
(setq *goal-id* nil)
(setq *footstep-list-bak* nil)
(setq *goal-id-bak* nil)
(setq *interruptible-mode* nil)

;; ((footstep footstep ....) (footstep footstep ....) ...)

(defun footstep->coords (footstep frame-id)
  ;; convert jsk_footstep_msgs/Footstep to euslisp coodinates
  ;; where `frame-id' is the frame-id of `footstep'
  (let ((coords (ros::tf-pose->coords (send footstep :pose))))
    ;; in order to specify :lleg or :rleg, we need to set property list
    ;; of coordinates object, it will be read by robot-interface.
    (send coords :name
          (if (= (send footstep :leg) jsk_footstep_msgs::Footstep::*LEFT*)
              :lleg
            :rleg))
    coords))

(setq *contact-header* nil)
(setq *contact-state* jsk_footstep_controller::GroundContactState::*CONTACT_UNSTABLE*)
(setq *contact-error* 0)
(defun contact-state-callback (msg)
  (setq *contact-state* (send msg :contact_state))
  (setq *contact-error* (send msg :error_pitch_angle))
  (setq *contact-header* (send msg :header))
  )

(defun contact-state->str (state)
  (cond
   ((eq state jsk_footstep_controller::GroundContactState::*CONTACT_UNSTABLE*)
    "unstable")
   ((eq state jsk_footstep_controller::GroundContactState::*CONTACT_BOTH_GROUND*)
    "ground")
   ((eq state jsk_footstep_controller::GroundContactState::*CONTACT_AIR*)
    "air")
   ((eq state jsk_footstep_controller::GroundContactState::*CONTACT_LLEG_GROUND*)
    "lleg")
   ((eq state jsk_footstep_controller::GroundContactState::*CONTACT_RLEG_GROUND*)
    "rleg")))

(defun wait-for-double-stance-phase ()
  (setq *contact-state* nil)
  (while (not (eq *contact-state* jsk_footstep_controller::GroundContactState::*CONTACT_BOTH_GROUND*))
    (ros::ros-info "contact state is ~A" (contact-state->str *contact-state*))
    (publish-breakpoint-text "Waiting for contact state to be stable")
    (ros::spin-once)
    (ros::sleep)))

(defun publish-breakpoint-text (text)
  (let ((msg (instance jsk_rviz_plugins::OverlayText :init)))
    (send msg :text text)
    (ros::publish "breakpoint_text" msg)))

(defun hrpsys-init-coords ()
  (let ((param (send *ri* :get-foot-step-param)))
    (midcoords
     0.5
     (send *ri* :abc-footstep->eus-footstep (send param :rleg_coords))
     (send *ri* :abc-footstep->eus-footstep (send param :lleg_coords)))))

(defun walking-pose
  (robot
   &key (root-link-height-offset 0) ;; [mm]
        (root-link-pitch-offset 0) ;; [deg]
        (fix-coords (make-coords))
        (default-pose-method :reset-manip-pose))
  (send robot default-pose-method)
  (send robot :fix-leg-to-coords fix-coords)
  (let ((lc (mapcar #'(lambda (l)
                        (send robot l :end-coords :copy-worldcoords))
                    '(:rleg :lleg))))
    (send robot :move-coords
          (send
           (send (send (car (send robot :links)) :copy-worldcoords)
                 :translate (float-vector 0 0 root-link-height-offset))
           :rotate (deg2rad root-link-pitch-offset) :y)
          (car (send robot :links)))
    (mapcar #'(lambda (l c)
                (send robot l :inverse-kinematics c))
            '(:rleg :lleg) lc)
    (send robot :move-centroid-on-foot :both '(:rleg :lleg))
    (send robot :angle-vector)
    ))


(defun new-goal-cb (server goal)
  ;; coordinate transformation:
  ;; 1. calc transformation from hrpsys-coords to footstep-coords[0].
  ;; 2. apply the inverse transformation to footstep-ocorods[1:]
  ;; 3. convert the footstep respected to hrpsys-mid-coords
  (if (not *interruptible-mode*)
      (when *realp*
        (walking-pose *hrp2jsknts* :root-link-height-offset -50)
        (send *ri* :angle-vector (send *hrp2jsknts* :angle-vector) 5000)
        (send *ri* :wait-interpolation)))
  (cond ((= (send goal :goal :strategy) jsk_footstep_msgs::ExecFootstepsGoal::*RESUME*)
         (progn
           (print 'resuming)
           (setq *footstep-list* *footstep-list-bak*)
           (setq *footstep-list-bak* nil)
           (setq *goal-id* (send goal :goal_id :id))))
        ((= (send goal :goal :strategy) jsk_footstep_msgs::ExecFootstepsGoal::*NEW_TARGET*)
         (let* ((footstep (send goal :goal :footstep)) ;jsk_footstep_msgs/FootstepArray
                (frame-id (send footstep :header :frame_id)))
           (let* ((footstep-coords            ; convert footstep to euslisp coords
                   (mapcar #'(lambda (footstep)
                               (footstep->coords footstep frame-id))
                           (send footstep :footsteps)))
                  (footstep-coords0 (car footstep-coords))
                  (footstep-coords-rest (cdr footstep-coords))
                  (hrpsys-coords (send *ri* :abc-footstep->eus-footstep
                                       (send (send *ri* :get-foot-step-param)
                                             (if (eq (send footstep-coords0 :name) :lleg)
                                                 :lleg_coords :rleg_coords))))
                  (hrpsys-mid-coords (hrpsys-init-coords)))
             (let* ((hrpsys->ros (send hrpsys-coords :transformation footstep-coords0))
                    (ros->hrpsys (send hrpsys->ros :inverse-transformation)))
               (let ((transformed-footstep
                      (mapcar
                       #'(lambda (footstep)
                           (let ((coords (send (send ros->hrpsys :copy-worldcoords)
                                               :transform footstep)))
                             (send coords :name (send footstep :name))
                             coords))
                       footstep-coords-rest)))
                 (let ((final-footstep
                        (mapcar
                         #'(lambda (footstep)
                             (let ((c (send hrpsys-mid-coords
                                            :transformation footstep)))
                               (send c :name (send footstep :name))
                               c))
                         transformed-footstep)))
                   (push final-footstep *all-the-results*)
                   (setq *footstep-list* final-footstep)
                   (setq *goal-id* (send goal :goal_id :id))
                   ))))))))


(defun walking-pose
  (robot
   &key (root-link-height-offset 0) ;; [mm]
        (root-link-pitch-offset 0) ;; [deg]
        (fix-coords (make-coords))
        (default-pose-method :reset-manip-pose))
  (send robot default-pose-method)
  (send robot :fix-leg-to-coords fix-coords)
  (let ((lc (mapcar #'(lambda (l)
                        (send robot l :end-coords :copy-worldcoords))
                    '(:rleg :lleg))))
    (send robot :move-coords
          (send
           (send (send (car (send robot :links)) :copy-worldcoords)
                 :translate (float-vector 0 0 root-link-height-offset))
           :rotate (deg2rad root-link-pitch-offset) :y)
          (car (send robot :links)))
    (mapcar #'(lambda (l c)
                (send robot l :inverse-kinematics c))
            '(:rleg :lleg) lc)
    (send robot :move-centroid-on-foot :both '(:rleg :lleg))
    (send robot :angle-vector)
    ))

(defun change-standing-mode (first-step next-step)
  (let ((next nil))
    (cond ((and (null first-step) (null next-step))
           (setq next :standing))
          ((> (abs (elt (send (send next-step :transformation first-step) :worldpos) 2)) 10) ;1cm
           (setq next :climing-up))
          ;; hack
          ;; ((eq *walking-state* :climing-up)
          ;;  (setq next :climing-up2))
          (t
           (setq next :plane)))
    (ros::ros-info "walking state: ~A ==> ~A" *walking-state* next)
    (cond
     ;; N
     ((or (and (eq next :standing) (eq *walking-state* :standing))
          (and (eq next :plane) (eq *walking-state* :plane))
          (and (eq *walking-state* :climing-up) (eq next :standing))
          (and (eq *walking-state* :climing-up) (eq next :climing-up2))
          (and (eq *walking-state* :climing-up2) (eq next :climing-up)))
      (ros::ros-warn "do nothing about posture")
      )
     ;; G
     ((or (and (eq *walking-state* :plane) (eq next :standing))
          (and (eq *walking-state* :climing-up2) (eq next :standing)))
      (when *realp*
        (walking-pose *hrp2jsknts* :root-link-height-offset 0)
        (send *ri* :angle-vector (send *hrp2jsknts* :angle-vector) 5000)
        (send *ri* :wait-interpolation)
        (send *ri* :set-gait-generator-param :default-orbit-type :cycloid))
      (ros::ros-warn "move down 0 mm and change mode to cycloid"))
     ;; A
     ((or (and (eq *walking-state* :standing) (eq next :plane))
          (and (eq *walking-state* :climing-up2) (eq next :plane)))
      (when *realp*
        (walking-pose *hrp2jsknts* :root-link-height-offset -50)
        (send *ri* :angle-vector (send *hrp2jsknts* :angle-vector) 5000)
        (send *ri* :wait-interpolation)
        (send *ri* :set-gait-generator-param :default-orbit-type :cycloid))
      (ros::ros-warn "move down -50 mm and change mode to cycloid"))
     ;; B
     ((or (and (eq *walking-state* :standing) (eq next :climing-up))
          (and (eq *walking-state* :plane) (eq next :climing-up)))
      
      (when *realp*
        (walking-pose *hrp2jsknts* :root-link-height-offset -90)
        (send *ri* :angle-vector (send *hrp2jsknts* :angle-vector) 5000)
        (send *ri* :wait-interpolation)
        (send *ri* :set-gait-generator-param :default-orbit-type :stair))
      (ros::ros-warn "move down -90 mm and change mode to stair"))
     (t
      (ros::ros-error "Unknown mode change ~A => ~A" *walking-state* next)))
    (setq *walking-state* next)))

(defun proc-goal-cb (server goal)
  (publish-breakpoint-text " ")
  (if *interruptible-mode*
      (progn
        (ros::ros-info "remaining footsteps: ~A" (length *footstep-list*))
        (cond ((<= (length *footstep-list*) 1) ;finish
               (progn
                 (change-standing-mode nil nil)
                 (publish-breakpoint-text " ")
                 (let ((result (send server :result)))
                   (send server :set-succeeded result))))
              (t
               (publish-breakpoint-text " ")
               (let ((first-step (pop *footstep-list*)))
                 (setq second-step (car *footstep-list*))
                       ;;(second-step (car *footstep-list*)))
                 (change-standing-mode first-step second-step)
                 (if (eq *walking-state* :climing-up) ;hack
                     (progn
                       (let ((third-step (cadr *footstep-list*)))
                         (when *realp*
                           (send *ri* :set-foot-steps (list first-step second-step third-step)))
                         (pop *footstep-list*)))
                   (when *realp*
                     (send *ri* :set-foot-steps (list first-step second-step)))
                   ))
               (when *wait-contact-state* 
                 ;;(unix:sleep 1)
                 (wait-for-double-stance-phase))
               (publish-breakpoint-text "Breakpoint!")
                ;;(format nil "Breakpoint!, error: ~A (~A)" *contact-error* (rad2deg *contact-error*)))
               (when *check-breakpoint*
                 (setq req (instance jsk_footstep_controller::RequireMonitorStatusRequest :init))
                   (send req :header *contact-header*)
                   (if(eq (send second-step :name) :rleg)
                       (send req :threshold (deg2rad 1.5)) ;lleg
                     (send req :threshold (deg2rad 1.7))) ;rleg
                   (let ((res (ros::service-call "require_foot_contact_monitor" req)))
                     (unless (send res :go)
                       (preempt-cb server nil)))))))
    (progn
      (print (send-all *footstep-list* :name))
      (when *realp*
        (send *ri* :set-foot-steps *footstep-list*))
      (setq *footstep-list* nil)
      (when *realp*
        (walking-pose *hrp2jsknts* :root-link-height-offset 0)
        (send *ri* :angle-vector (send *hrp2jsknts* :angle-vector) 5000)
        (send *ri* :wait-interpolation))
      (send server :set-succeeded (send server :result))
      )
    ))

(defun preempt-cb (server goal)
  (print 'preempt-cb)
  (setq *footstep-list-bak* *footstep-list*)
  (setq *footstep-list* nil)
  (send server :set-preempted)
  (setq *goal-id-bak* *goal-id*)
  (setq *goal-id* nil)
  ;; cancel broadcast
  (ros::publish "/footstep_cancel_broadcast" (instance std_msgs::Empty :init))
  )

(defun execute-cb (server goal)
  (print 'execute-cb)
  (if (or (null *goal-id*)
          (not (string= *goal-id* (send goal :goal_id :id))))
      (new-goal-cb server goal)
    (proc-goal-cb server goal)))

(defun require-log-service-callback (req)
  (let ((res (send req :response)))
    (let ((*print-object* t) (*print-circle* t)
          (*print-level* nil) (*print-length* nil))
      (send res :sexp (format nil "~A" *all-the-results*))
      res)))

(defun main()
  (ros::roseus "footstep_controller")
  ;; *ri*
  (let ((interface-file
         (ros::get-param "~interface_file"
           "package://hrpsys_ros_bridge_tutorials/euslisp/hrp2jsknt-interface.l"))
        (interface-class
         (ros::get-param "~interface_class" "hrp2jsknt-interface")))
    (setq *interruptible-mode* (ros::get-param "~interruptible_mode" nil))
    (if *interruptible-mode*
        (ros::ros-info "footstep controller running in interruptible mode"))
    (load interface-file)
    (setq *ri* (instance (eval (read-from-string interface-class)) :init
                         :controller-timeout nil))
    ;; 
    (hrp2jsknts-init))
  ;; interface
  (setq *tf* (instance ros::transform-listener :init))
  (ros::advertise-service "require_log"
    jsk_footstep_controller::RequireLog
    #'require-log-service-callback)
  (ros::advertise "breakpoint_text" jsk_rviz_plugins::OverlayText)
  (ros::subscribe "/footcoords/contact_state" 
                  jsk_footstep_controller::GroundContactState
                  #'contact-state-callback)
  (ros::advertise "/footstep_cancel_broadcast" std_msgs::Empty)
  ;; client self-client to cancel itself
  (unix:sleep 1)
  (publish-breakpoint-text " ")
  (let ((s (instance ros::simple-action-server :init
                     "footstep_controller"
                     jsk_footstep_msgs::ExecFootstepsAction
                     :execute-cb 'execute-cb
                     :preempt-cb 'preempt-cb)))
    (ros::rate 10)
    (ros::ros-info "footstep controller is ready")
    (while (ros::ok)
      (send s :worker)
      (ros::spin-once)
      (ros::sleep))))

(main)


#|
(setq aa '((#J(coordinates ((:name . :rleg)) #J(array nil #f(0.99987 0.002702 0.01588 -0.002847 0.999954 0.009123 -0.015855 -0.009167 0.999832) 2 nil 0 3 3 nil nil nil nil nil) #f(-2.5818 -134.762 -11.945)) #J(coordinates ((:name . :lleg)) #J(array nil #f(0.999716 0.000819 0.02382 -0.000794 0.999999 -0.001046 -0.023821 0.001027 0.999716) 2 nil 0 3 3 nil nil nil nil nil) #f(94.3242 52.2552 -16.8706)) #J(coordinates ((:name . :rleg)) #J(array nil #f(0.999716 0.000819 0.02382 -0.000794 0.999999 -0.001046 -0.023821 0.001027 0.999716) 2 nil 0 3 3 nil nil nil nil nil) #f(94.1522 -157.745 -17.0863)))))
(dotimes (i (1- (length footsteps)))
  (print (rad2deg (acos (v. (normalize-vector (send (elt footsteps i) :z-axis)) (normalize-vector (send (elt footsteps (1+ i)) :z-axis)))))
  )
|#
