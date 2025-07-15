;; Event Organization Contract
;; Manages networking events and professional gatherings

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-EVENT-NOT-FOUND (err u301))
(define-constant ERR-INVALID-INPUT (err u302))
(define-constant ERR-EVENT-FULL (err u303))
(define-constant ERR-ALREADY-REGISTERED (err u304))
(define-constant ERR-REGISTRATION-CLOSED (err u305))
(define-constant ERR-EVENT-NOT-STARTED (err u306))

;; Data Variables
(define-data-var next-event-id uint u1)
(define-data-var total-events uint u0)

;; Data Maps
(define-map events
  { event-id: uint }
  {
    organizer: principal,
    title: (string-ascii 100),
    description: (string-ascii 500),
    event-date: uint,
    max-attendees: uint,
    current-attendees: uint,
    registration-fee: uint,
    status: (string-ascii 20),
    created-at: uint,
    category: (string-ascii 50),
    location: (string-ascii 100)
  }
)

(define-map event-registrations
  { event-id: uint, attendee: principal }
  {
    registered-at: uint,
    attended: bool,
    rating: (optional uint),
    feedback: (optional (string-ascii 200))
  }
)

(define-map event-tokens
  { user: principal }
  { balance: uint }
)

(define-map organizer-stats
  { organizer: principal }
  {
    events-organized: uint,
    total-attendees: uint,
    average-rating: uint,
    reputation-score: uint
  }
)

;; Token Functions
(define-private (mint-tokens (recipient principal) (amount uint))
  (let ((current-balance (default-to u0 (get balance (map-get? event-tokens { user: recipient })))))
    (map-set event-tokens
      { user: recipient }
      { balance: (+ current-balance amount) }
    )
  )
)

(define-private (transfer-tokens (from principal) (to principal) (amount uint))
  (let (
    (from-balance (default-to u0 (get balance (map-get? event-tokens { user: from }))))
    (to-balance (default-to u0 (get balance (map-get? event-tokens { user: to }))))
  )
    (if (>= from-balance amount)
      (begin
        (map-set event-tokens { user: from } { balance: (- from-balance amount) })
        (map-set event-tokens { user: to } { balance: (+ to-balance amount) })
        (ok true)
      )
      (err u999)
    )
  )
)

;; Event Management
(define-public (create-event (title (string-ascii 100)) (description (string-ascii 500)) (event-date uint) (max-attendees uint))
  (let ((event-id (var-get next-event-id)))
    (asserts! (> (len title) u0) ERR-INVALID-INPUT)
    (asserts! (> (len description) u0) ERR-INVALID-INPUT)
    (asserts! (> event-date block-height) ERR-INVALID-INPUT)
    (asserts! (> max-attendees u0) ERR-INVALID-INPUT)
    (asserts! (<= max-attendees u1000) ERR-INVALID-INPUT)

    (map-set events
      { event-id: event-id }
      {
        organizer: tx-sender,
        title: title,
        description: description,
        event-date: event-date,
        max-attendees: max-attendees,
        current-attendees: u0,
        registration-fee: u0,
        status: "upcoming",
        created-at: block-height,
        category: "networking",
        location: "TBD"
      }
    )

    (var-set next-event-id (+ event-id u1))
    (var-set total-events (+ (var-get total-events) u1))

    ;; Update organizer stats
    (update-organizer-stats tx-sender)

    ;; Reward event creation
    (mint-tokens tx-sender u150)

    (ok event-id)
  )
)

(define-public (update-event (event-id uint) (title (string-ascii 100)) (description (string-ascii 500)) (location (string-ascii 100)))
  (let ((event (unwrap! (map-get? events { event-id: event-id }) ERR-EVENT-NOT-FOUND)))
    (asserts! (is-eq tx-sender (get organizer event)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status event) "upcoming") ERR-INVALID-INPUT)
    (asserts! (> (len title) u0) ERR-INVALID-INPUT)
    (asserts! (> (len description) u0) ERR-INVALID-INPUT)

    (map-set events
      { event-id: event-id }
      (merge event {
        title: title,
        description: description,
        location: location
      })
    )

    (ok true)
  )
)

(define-public (set-registration-fee (event-id uint) (fee uint))
  (let ((event (unwrap! (map-get? events { event-id: event-id }) ERR-EVENT-NOT-FOUND)))
    (asserts! (is-eq tx-sender (get organizer event)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status event) "upcoming") ERR-INVALID-INPUT)

    (map-set events
      { event-id: event-id }
      (merge event { registration-fee: fee })
    )

    (ok true)
  )
)

;; Registration Management
(define-public (register-for-event (event-id uint))
  (let ((event (unwrap! (map-get? events { event-id: event-id }) ERR-EVENT-NOT-FOUND)))
    (asserts! (is-eq (get status event) "upcoming") ERR-REGISTRATION-CLOSED)
    (asserts! (< (get current-attendees event) (get max-attendees event)) ERR-EVENT-FULL)
    (asserts! (is-none (map-get? event-registrations { event-id: event-id, attendee: tx-sender })) ERR-ALREADY-REGISTERED)
    (asserts! (> (get event-date event) block-height) ERR-REGISTRATION-CLOSED)

    ;; Handle registration fee
    (if (> (get registration-fee event) u0)
      (try! (transfer-tokens tx-sender (get organizer event) (get registration-fee event)))
      true
    )

    (map-set event-registrations
      { event-id: event-id, attendee: tx-sender }
      {
        registered-at: block-height,
        attended: false,
        rating: none,
        feedback: none
      }
    )

    (map-set events
      { event-id: event-id }
      (merge event { current-attendees: (+ (get current-attendees event) u1) })
    )

    ;; Reward registration
    (mint-tokens tx-sender u25)

    (ok true)
  )
)

(define-public (mark-attendance (event-id uint) (attendee principal))
  (let (
    (event (unwrap! (map-get? events { event-id: event-id }) ERR-EVENT-NOT-FOUND))
    (registration (unwrap! (map-get? event-registrations { event-id: event-id, attendee: attendee }) ERR-INVALID-INPUT))
  )
    (asserts! (is-eq tx-sender (get organizer event)) ERR-NOT-AUTHORIZED)
    (asserts! (>= block-height (get event-date event)) ERR-EVENT-NOT-STARTED)

    (map-set event-registrations
      { event-id: event-id, attendee: attendee }
      (merge registration { attended: true })
    )

    ;; Reward attendance
    (mint-tokens attendee u75)
    (mint-tokens (get organizer event) u25)

    (ok true)
  )
)

(define-public (complete-event (event-id uint))
  (let ((event (unwrap! (map-get? events { event-id: event-id }) ERR-EVENT-NOT-FOUND)))
    (asserts! (is-eq tx-sender (get organizer event)) ERR-NOT-AUTHORIZED)
    (asserts! (>= block-height (get event-date event)) ERR-EVENT-NOT-STARTED)
    (asserts! (is-eq (get status event) "upcoming") ERR-INVALID-INPUT)

    (map-set events
      { event-id: event-id }
      (merge event { status: "completed" })
    )

    ;; Bonus for successful event completion
    (mint-tokens (get organizer event) u200)

    (ok true)
  )
)

;; Feedback and Rating
(define-public (rate-event (event-id uint) (rating uint) (feedback (string-ascii 200)))
  (let (
    (event (unwrap! (map-get? events { event-id: event-id }) ERR-EVENT-NOT-FOUND))
    (registration (unwrap! (map-get? event-registrations { event-id: event-id, attendee: tx-sender }) ERR-NOT-AUTHORIZED))
  )
    (asserts! (get attended registration) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status event) "completed") ERR-INVALID-INPUT)
    (asserts! (and (>= rating u1) (<= rating u5)) ERR-INVALID-INPUT)
    (asserts! (is-none (get rating registration)) ERR-INVALID-INPUT)

    (map-set event-registrations
      { event-id: event-id, attendee: tx-sender }
      (merge registration {
        rating: (some rating),
        feedback: (some feedback)
      })
    )

    ;; Update organizer rating
    (update-organizer-rating (get organizer event) rating)

    ;; Reward feedback
    (mint-tokens tx-sender u30)

    (ok true)
  )
)

;; Helper Functions
(define-private (update-organizer-stats (organizer principal))
  (let ((current-stats (default-to { events-organized: u0, total-attendees: u0, average-rating: u5, reputation-score: u100 }
                                   (map-get? organizer-stats { organizer: organizer }))))
    (map-set organizer-stats
      { organizer: organizer }
      (merge current-stats { events-organized: (+ (get events-organized current-stats) u1) })
    )
  )
)

(define-private (update-organizer-rating (organizer principal) (new-rating uint))
  (let ((stats (default-to { events-organized: u1, total-attendees: u0, average-rating: u5, reputation-score: u100 }
                           (map-get? organizer-stats { organizer: organizer }))))
    (let ((current-rating (get average-rating stats))
          (events-count (get events-organized stats)))
      (if (> events-count u1)
        (let ((updated-rating (/ (+ (* current-rating (- events-count u1)) new-rating) events-count)))
          (map-set organizer-stats
            { organizer: organizer }
            (merge stats { average-rating: updated-rating })
          )
        )
        (map-set organizer-stats
          { organizer: organizer }
          (merge stats { average-rating: new-rating })
        )
      )
    )
  )
)

;; Read-only Functions
(define-read-only (get-event (event-id uint))
  (map-get? events { event-id: event-id })
)

(define-read-only (get-registration (event-id uint) (attendee principal))
  (map-get? event-registrations { event-id: event-id, attendee: attendee })
)

(define-read-only (get-organizer-stats (organizer principal))
  (map-get? organizer-stats { organizer: organizer })
)

(define-read-only (get-token-balance (user principal))
  (default-to u0 (get balance (map-get? event-tokens { user: user })))
)

(define-read-only (get-total-events)
  (var-get total-events)
)

(define-read-only (is-registered (event-id uint) (attendee principal))
  (is-some (map-get? event-registrations { event-id: event-id, attendee: attendee }))
)
