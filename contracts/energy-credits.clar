;; Title: Energy Credits Token (ENC)
;; Description: SIP-010 compliant token for trading energy credits on Enertrade marketplace
;; Each token represents 1 kWh of verified renewable energy production

;; SIP-010 compliant fungible token implementation
;; Note: Implementing core SIP-010 functions without external trait import

;; Define the energy credits fungible token
(define-fungible-token energy-credits)

;; Error constants
(define-constant err-owner-only (err u100))
(define-constant err-not-token-owner (err u101))
(define-constant err-insufficient-balance (err u102))
(define-constant err-invalid-amount (err u103))
(define-constant err-unauthorized (err u104))
(define-constant err-producer-not-registered (err u105))
(define-constant err-producer-already-registered (err u106))
(define-constant err-invalid-energy-type (err u107))
(define-constant err-verification-failed (err u108))
(define-constant err-credit-expired (err u109))
(define-constant err-invalid-metadata (err u110))

;; Contract constants
(define-constant contract-owner tx-sender)
(define-constant max-supply u1000000000000) ;; 1 trillion credits max
(define-constant min-mint-amount u1) ;; Minimum 1 kWh credit
(define-constant credit-validity-period u52560) ;; ~1 year in blocks
(define-constant verification-fee u100) ;; Fee in microSTX

;; Token metadata
(define-data-var token-name (string-ascii 32) "Energy Credits")
(define-data-var token-symbol (string-ascii 10) "ENC")
(define-data-var token-uri (optional (string-utf8 256)) none)
(define-data-var token-decimals uint u6)

;; Contract state variables
(define-data-var total-producers uint u0)
(define-data-var total-verified-credits uint u0)
(define-data-var contract-paused bool false)

;; Energy types enum
(define-constant energy-type-solar u1)
(define-constant energy-type-wind u2)
(define-constant energy-type-hydro u3)
(define-constant energy-type-geothermal u4)
(define-constant energy-type-biomass u5)

;; Producer registration data structure
(define-map producers principal {
    name: (string-utf8 50),
    energy-type: uint,
    capacity-kw: uint,
    location: (string-utf8 100),
    verification-status: bool,
    registration-block: uint,
    total-credits-issued: uint,
    is-active: bool
})

;; Credit issuance records
(define-map credit-issuances uint {
    producer: principal,
    amount: uint,
    energy-type: uint,
    production-period-start: uint,
    production-period-end: uint,
    verification-hash: (buff 32),
    issued-at-block: uint,
    verified-by: principal,
    is-verified: bool
})

;; Credit metadata for tracking purposes
(define-map credit-metadata principal {
    total-earned: uint,
    total-spent: uint,
    last-activity-block: uint,
    credits-from-solar: uint,
    credits-from-wind: uint,
    credits-from-other: uint
})

;; Verification authorities
(define-map authorized-verifiers principal bool)

;; State tracking
(define-data-var next-issuance-id uint u1)

;; SIP-010 Standard Functions

(define-public (get-name)
    (ok (var-get token-name))
)

(define-public (get-symbol)
    (ok (var-get token-symbol))
)

(define-public (get-decimals)
    (ok (var-get token-decimals))
)

(define-public (get-balance (who principal))
    (ok (ft-get-balance energy-credits who))
)

(define-public (get-total-supply)
    (ok (ft-get-supply energy-credits))
)

(define-public (get-token-uri)
    (ok (var-get token-uri))
)

(define-public (transfer (amount uint) (from principal) (to principal) (memo (optional (buff 34))))
    (begin
        (asserts! (not (var-get contract-paused)) err-unauthorized)
        (asserts! (> amount u0) err-invalid-amount)
        (asserts! (or (is-eq tx-sender from) (is-eq contract-caller from)) err-not-token-owner)
        
        ;; Update credit metadata for both parties
        (update-credit-metadata-on-transfer from to amount)
        
        ;; Execute transfer
        (match (ft-transfer? energy-credits amount from to)
            success (ok success)
            error (err error)
        )
    )
)

;; Producer Management Functions

(define-public (register-producer (name (string-utf8 50)) (energy-type uint) (capacity-kw uint) (location (string-utf8 100)))
    (let (
        (producer tx-sender)
    )
        (asserts! (not (var-get contract-paused)) err-unauthorized)
        (asserts! (is-none (map-get? producers producer)) err-producer-already-registered)
        (asserts! (and (>= energy-type u1) (<= energy-type u5)) err-invalid-energy-type)
        (asserts! (> capacity-kw u0) err-invalid-amount)
        
        ;; Register the producer
        (map-set producers producer {
            name: name,
            energy-type: energy-type,
            capacity-kw: capacity-kw,
            location: location,
            verification-status: false,
            registration-block: stacks-block-height,
            total-credits-issued: u0,
            is-active: true
        })
        
        ;; Initialize credit metadata
        (map-set credit-metadata producer {
            total-earned: u0,
            total-spent: u0,
            last-activity-block: stacks-block-height,
            credits-from-solar: u0,
            credits-from-wind: u0,
            credits-from-other: u0
        })
        
        ;; Update total producers count
        (var-set total-producers (+ (var-get total-producers) u1))
        
        (ok true)
    )
)

(define-public (verify-producer (producer principal))
    (let (
        (producer-data (unwrap! (map-get? producers producer) err-producer-not-registered))
    )
        (asserts! (is-authorized-verifier tx-sender) err-unauthorized)
        (asserts! (not (get verification-status producer-data)) err-unauthorized)
        
        ;; Update producer verification status
        (map-set producers producer (merge producer-data { verification-status: true }))
        
        (ok true)
    )
)

;; Credit Issuance Functions

(define-public (mint-energy-credits 
    (recipient principal) 
    (amount uint) 
    (energy-type uint)
    (production-period-start uint)
    (production-period-end uint)
    (verification-hash (buff 32))
)
    (let (
        (issuance-id (var-get next-issuance-id))
        (producer-data (unwrap! (map-get? producers recipient) err-producer-not-registered))
    )
        (asserts! (not (var-get contract-paused)) err-unauthorized)
        (asserts! (is-authorized-verifier tx-sender) err-unauthorized)
        (asserts! (>= amount min-mint-amount) err-invalid-amount)
        (asserts! (get verification-status producer-data) err-verification-failed)
        (asserts! (get is-active producer-data) err-unauthorized)
        (asserts! (< production-period-start production-period-end) err-invalid-metadata)
        (asserts! (<= (+ (ft-get-supply energy-credits) amount) max-supply) err-invalid-amount)
        
        ;; Record the credit issuance
        (map-set credit-issuances issuance-id {
            producer: recipient,
            amount: amount,
            energy-type: energy-type,
            production-period-start: production-period-start,
            production-period-end: production-period-end,
            verification-hash: verification-hash,
            issued-at-block: stacks-block-height,
            verified-by: tx-sender,
            is-verified: true
        })
        
        ;; Update producer's total issued credits
        (map-set producers recipient 
            (merge producer-data 
                { total-credits-issued: (+ (get total-credits-issued producer-data) amount) }
            )
        )
        
        ;; Update credit metadata
        (update-earned-credits recipient amount energy-type)
        
        ;; Increment issuance ID
        (var-set next-issuance-id (+ issuance-id u1))
        
        ;; Mint the tokens
        (match (ft-mint? energy-credits amount recipient)
            success (begin
                (var-set total-verified-credits (+ (var-get total-verified-credits) amount))
                (ok success)
            )
            error (err error)
        )
    )
)

;; Authorization Functions

(define-public (add-authorized-verifier (verifier principal))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (map-set authorized-verifiers verifier true)
        (ok true)
    )
)

(define-public (remove-authorized-verifier (verifier principal))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (map-delete authorized-verifiers verifier)
        (ok true)
    )
)

;; Utility Functions

(define-private (is-authorized-verifier (verifier principal))
    (default-to false (map-get? authorized-verifiers verifier))
)

(define-private (update-credit-metadata-on-transfer (from principal) (to principal) (amount uint))
    (let (
        (from-metadata (default-to { total-earned: u0, total-spent: u0, last-activity-block: u0, credits-from-solar: u0, credits-from-wind: u0, credits-from-other: u0 } 
                                   (map-get? credit-metadata from)))
        (to-metadata (default-to { total-earned: u0, total-spent: u0, last-activity-block: u0, credits-from-solar: u0, credits-from-wind: u0, credits-from-other: u0 } 
                                 (map-get? credit-metadata to)))
    )
        ;; Update sender metadata
        (map-set credit-metadata from 
            (merge from-metadata {
                total-spent: (+ (get total-spent from-metadata) amount),
                last-activity-block: stacks-block-height
            })
        )
        
        ;; Update receiver metadata  
        (map-set credit-metadata to 
            (merge to-metadata {
                total-earned: (+ (get total-earned to-metadata) amount),
                last-activity-block: stacks-block-height
            })
        )
    )
)

(define-private (update-earned-credits (recipient principal) (amount uint) (energy-type uint))
    (let (
        (current-metadata (default-to { total-earned: u0, total-spent: u0, last-activity-block: u0, credits-from-solar: u0, credits-from-wind: u0, credits-from-other: u0 } 
                                     (map-get? credit-metadata recipient)))
    )
        (map-set credit-metadata recipient 
            (merge current-metadata {
                total-earned: (+ (get total-earned current-metadata) amount),
                last-activity-block: stacks-block-height,
                credits-from-solar: (if (is-eq energy-type energy-type-solar) 
                                      (+ (get credits-from-solar current-metadata) amount)
                                      (get credits-from-solar current-metadata)),
                credits-from-wind: (if (is-eq energy-type energy-type-wind)
                                     (+ (get credits-from-wind current-metadata) amount)
                                     (get credits-from-wind current-metadata)),
                credits-from-other: (if (and (not (is-eq energy-type energy-type-solar)) (not (is-eq energy-type energy-type-wind)))
                                      (+ (get credits-from-other current-metadata) amount)
                                      (get credits-from-other current-metadata))
            })
        )
    )
)

;; Read-only functions for querying data

(define-read-only (get-producer-info (producer principal))
    (map-get? producers producer)
)

(define-read-only (get-credit-metadata (user principal))
    (map-get? credit-metadata user)
)

(define-read-only (get-issuance-info (issuance-id uint))
    (map-get? credit-issuances issuance-id)
)

(define-read-only (get-contract-stats)
    {
        total-supply: (ft-get-supply energy-credits),
        total-producers: (var-get total-producers),
        total-verified-credits: (var-get total-verified-credits),
        contract-paused: (var-get contract-paused),
        next-issuance-id: (var-get next-issuance-id)
    }
)

;; Administrative functions

(define-public (pause-contract)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set contract-paused true)
        (ok true)
    )
)

(define-public (unpause-contract)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set contract-paused false)
        (ok true)
    )
)

;; Initialize the contract owner as the first authorized verifier
(map-set authorized-verifiers contract-owner true)
