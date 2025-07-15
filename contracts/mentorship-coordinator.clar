;; Mentorship Coordination Contract
;; Pairs experienced professionals with career seekers

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-MENTOR-NOT-FOUND (err u201))
(define-constant ERR-MENTEE-NOT-FOUND (err u202))
(define-constant ERR-INVALID-INPUT (err u203))
(define-constant ERR-INSUFFICIENT-TOKENS (err u204))
(define-constant ERR-MENTORSHIP-EXISTS (err u205))
(define-constant ERR-MENTORSHIP-NOT-FOUND (err u206))

;; Data Variables
(define-data-var next-mentor-id uint u1)
(define-data-var next-mentorship-id uint u1)
(define-data-var total-mentorships uint u0)

;; Data Maps
(define-map mentors
  { user: principal }
  {
    mentor-id: uint,
    expertise-area: (string-ascii 100),
    experience-years: uint,
    hourly-rate: uint,
    availability: bool,
    total-mentees: uint,
    rating: uint,
    is-verified: bool
  }
)

(define-map mentorships
  { mentorship-id: uint }
  {
    mentor: principal,
    mentee: principal,
    goal: (string-ascii 200),
    duration-weeks: uint,
    payment-amount: uint,
    status: (string-ascii 20),
    created-at: uint,
    started-at: (optional uint),
    completed-at: (optional uint),
    mentor-rating: (optional uint),
    mentee-rating: (optional uint)
  }
)

(define-map mentorship-tokens
  { user: principal }
  { balance: uint }
)

(define-map mentorship-milestones
  { mentorship-id: uint, milestone-id: uint }
  {
    description: (string-ascii 200),
    is-completed: bool,
    completed-at: (optional uint),
    reward-amount: uint
  }
)

;; Token Functions
(define-private (mint-tokens (recipient principal) (amount uint))
  (let ((current-balance (default-to u0 (get balance (map-get? mentorship-tokens { user: recipient })))))
    (map-set mentorship-tokens
      { user: recipient }
      { balance: (+ current-balance amount) }
    )
  )
)

(define-private (transfer-tokens (from principal) (to principal) (amount uint))
  (let (
    (from-balance (default-to u0 (get balance (map-get? mentorship-tokens { user: from }))))
    (to-balance (default-to u0 (get balance (map-get? mentorship-tokens { user: to }))))
  )
    (if (>= from-balance amount)
      (begin
        (map-set mentorship-tokens { user: from } { balance: (- from-balance amount) })
        (map-set mentorship-tokens { user: to } { balance: (+ to-balance amount) })
        (ok true)
      )
      ERR-INSUFFICIENT-TOKENS
    )
  )
)

;; Mentor Registration
(define-public (register-as-mentor (expertise-area (string-ascii 100)) (experience-years uint) (hourly-rate uint))
  (let ((mentor-id (var-get next-mentor-id)))
    (asserts! (is-none (map-get? mentors { user: tx-sender })) ERR-MENTOR-NOT-FOUND)
    (asserts! (> (len expertise-area) u0) ERR-INVALID-INPUT)
    (asserts! (> experience-years u0) ERR-INVALID-INPUT)
    (asserts! (> hourly-rate u0) ERR-INVALID-INPUT)

    (map-set mentors
      { user: tx-sender }
      {
        mentor-id: mentor-id,
        expertise-area: expertise-area,
        experience-years: experience-years,
        hourly-rate: hourly-rate,
        availability: true,
        total-mentees: u0,
        rating: u5,
        is-verified: false
      }
    )

    (var-set next-mentor-id (+ mentor-id u1))
    (mint-tokens tx-sender u200)
    (ok mentor-id)
  )
)

(define-public (update-mentor-availability (available bool))
  (let ((mentor (unwrap! (map-get? mentors { user: tx-sender }) ERR-MENTOR-NOT-FOUND)))
    (map-set mentors
      { user: tx-sender }
      (merge mentor { availability: available })
    )
    (ok true)
  )
)

;; Mentorship Management
(define-public (request-mentorship (mentor principal) (goal (string-ascii 200)) (payment-amount uint))
  (let (
    (mentorship-id (var-get next-mentorship-id))
    (mentor-info (unwrap! (map-get? mentors { user: mentor }) ERR-MENTOR-NOT-FOUND))
  )
    (asserts! (not (is-eq tx-sender mentor)) ERR-INVALID-INPUT)
    (asserts! (get availability mentor-info) ERR-INVALID-INPUT)
    (asserts! (> (len goal) u0) ERR-INVALID-INPUT)
    (asserts! (> payment-amount u0) ERR-INVALID-INPUT)
    (asserts! (>= (get-token-balance tx-sender) payment-amount) ERR-INSUFFICIENT-TOKENS)

    (map-set mentorships
      { mentorship-id: mentorship-id }
      {
        mentor: mentor,
        mentee: tx-sender,
        goal: goal,
        duration-weeks: u12,
        payment-amount: payment-amount,
        status: "pending",
        created-at: block-height,
        started-at: none,
        completed-at: none,
        mentor-rating: none,
        mentee-rating: none
      }
    )

    (var-set next-mentorship-id (+ mentorship-id u1))
    (ok mentorship-id)
  )
)

(define-public (accept-mentorship (mentorship-id uint))
  (let ((mentorship (unwrap! (map-get? mentorships { mentorship-id: mentorship-id }) ERR-MENTORSHIP-NOT-FOUND)))
    (asserts! (is-eq tx-sender (get mentor mentorship)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status mentorship) "pending") ERR-INVALID-INPUT)

    ;; Transfer payment to escrow (simplified - in practice would use proper escrow)
    (try! (transfer-tokens (get mentee mentorship) (get mentor mentorship) (/ (get payment-amount mentorship) u2)))

    (map-set mentorships
      { mentorship-id: mentorship-id }
      (merge mentorship {
        status: "active",
        started-at: (some block-height)
      })
    )

    ;; Update mentor stats
    (let ((mentor-info (unwrap-panic (map-get? mentors { user: (get mentor mentorship) }))))
      (map-set mentors
        { user: (get mentor mentorship) }
        (merge mentor-info { total-mentees: (+ (get total-mentees mentor-info) u1) })
      )
    )

    (var-set total-mentorships (+ (var-get total-mentorships) u1))
    (ok true)
  )
)

(define-public (complete-mentorship (mentorship-id uint))
  (let ((mentorship (unwrap! (map-get? mentorships { mentorship-id: mentorship-id }) ERR-MENTORSHIP-NOT-FOUND)))
    (asserts! (or (is-eq tx-sender (get mentor mentorship)) (is-eq tx-sender (get mentee mentorship))) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status mentorship) "active") ERR-INVALID-INPUT)

    (map-set mentorships
      { mentorship-id: mentorship-id }
      (merge mentorship {
        status: "completed",
        completed-at: (some block-height)
      })
    )

    ;; Release remaining payment and bonus tokens
    (try! (transfer-tokens (get mentee mentorship) (get mentor mentorship) (/ (get payment-amount mentorship) u2)))
    (mint-tokens (get mentor mentorship) u100)
    (mint-tokens (get mentee mentorship) u50)

    (ok true)
  )
)

(define-public (rate-mentor (mentorship-id uint) (rating uint))
  (let ((mentorship (unwrap! (map-get? mentorships { mentorship-id: mentorship-id }) ERR-MENTORSHIP-NOT-FOUND)))
    (asserts! (is-eq tx-sender (get mentee mentorship)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status mentorship) "completed") ERR-INVALID-INPUT)
    (asserts! (and (>= rating u1) (<= rating u5)) ERR-INVALID-INPUT)

    (map-set mentorships
      { mentorship-id: mentorship-id }
      (merge mentorship { mentor-rating: (some rating) })
    )

    ;; Update mentor's overall rating
    (update-mentor-rating (get mentor mentorship) rating)

    (ok true)
  )
)

(define-public (rate-mentee (mentorship-id uint) (rating uint))
  (let ((mentorship (unwrap! (map-get? mentorships { mentorship-id: mentorship-id }) ERR-MENTORSHIP-NOT-FOUND)))
    (asserts! (is-eq tx-sender (get mentor mentorship)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status mentorship) "completed") ERR-INVALID-INPUT)
    (asserts! (and (>= rating u1) (<= rating u5)) ERR-INVALID-INPUT)

    (map-set mentorships
      { mentorship-id: mentorship-id }
      (merge mentorship { mentee-rating: (some rating) })
    )

    (ok true)
  )
)

;; Milestone Management
(define-public (add-milestone (mentorship-id uint) (milestone-id uint) (description (string-ascii 200)) (reward-amount uint))
  (let ((mentorship (unwrap! (map-get? mentorships { mentorship-id: mentorship-id }) ERR-MENTORSHIP-NOT-FOUND)))
    (asserts! (is-eq tx-sender (get mentor mentorship)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status mentorship) "active") ERR-INVALID-INPUT)
    (asserts! (> (len description) u0) ERR-INVALID-INPUT)

    (map-set mentorship-milestones
      { mentorship-id: mentorship-id, milestone-id: milestone-id }
      {
        description: description,
        is-completed: false,
        completed-at: none,
        reward-amount: reward-amount
      }
    )

    (ok true)
  )
)

(define-public (complete-milestone (mentorship-id uint) (milestone-id uint))
  (let (
    (mentorship (unwrap! (map-get? mentorships { mentorship-id: mentorship-id }) ERR-MENTORSHIP-NOT-FOUND))
    (milestone (unwrap! (map-get? mentorship-milestones { mentorship-id: mentorship-id, milestone-id: milestone-id }) ERR-INVALID-INPUT))
  )
    (asserts! (is-eq tx-sender (get mentee mentorship)) ERR-NOT-AUTHORIZED)
    (asserts! (not (get is-completed milestone)) ERR-INVALID-INPUT)

    (map-set mentorship-milestones
      { mentorship-id: mentorship-id, milestone-id: milestone-id }
      (merge milestone {
        is-completed: true,
        completed-at: (some block-height)
      })
    )

    ;; Reward milestone completion
    (mint-tokens (get mentee mentorship) (get reward-amount milestone))
    (mint-tokens (get mentor mentorship) (/ (get reward-amount milestone) u2))

    (ok true)
  )
)

;; Helper Functions
(define-private (update-mentor-rating (mentor principal) (new-rating uint))
  (let ((mentor-info (unwrap-panic (map-get? mentors { user: mentor }))))
    (let ((current-rating (get rating mentor-info))
          (total-mentees (get total-mentees mentor-info)))
      (if (> total-mentees u1)
        (let ((updated-rating (/ (+ (* current-rating (- total-mentees u1)) new-rating) total-mentees)))
          (map-set mentors
            { user: mentor }
            (merge mentor-info { rating: updated-rating })
          )
        )
        (map-set mentors
          { user: mentor }
          (merge mentor-info { rating: new-rating })
        )
      )
    )
  )
)

;; Read-only Functions
(define-read-only (get-mentor (user principal))
  (map-get? mentors { user: user })
)

(define-read-only (get-mentorship (mentorship-id uint))
  (map-get? mentorships { mentorship-id: mentorship-id })
)

(define-read-only (get-milestone (mentorship-id uint) (milestone-id uint))
  (map-get? mentorship-milestones { mentorship-id: mentorship-id, milestone-id: milestone-id })
)

(define-read-only (get-token-balance (user principal))
  (default-to u0 (get balance (map-get? mentorship-tokens { user: user })))
)

(define-read-only (get-total-mentorships)
  (var-get total-mentorships)
)
