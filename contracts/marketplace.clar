;; Title: Energy Credit Marketplace
;; Description: P2P marketplace for trading energy credits with order book functionality
;; Facilitates buying and selling of energy credits between producers and consumers

;; Energy credits contract reference
;; Note: Direct contract calls to energy-credits contract

;; Error constants
(define-constant err-owner-only (err u200))
(define-constant err-unauthorized (err u201))
(define-constant err-invalid-amount (err u202))
(define-constant err-invalid-price (err u203))
(define-constant err-order-not-found (err u204))
(define-constant err-order-already-filled (err u205))
(define-constant err-insufficient-balance (err u206))
(define-constant err-cannot-fill-own-order (err u207))
(define-constant err-marketplace-paused (err u208))
(define-constant err-invalid-order-type (err u209))
(define-constant err-order-expired (err u210))
(define-constant err-insufficient-collateral (err u211))
(define-constant err-invalid-fee-rate (err u212))

;; Contract constants
(define-constant contract-owner tx-sender)
(define-constant energy-credits-contract .energy-credits)
(define-constant max-fee-rate u1000) ;; 10% max fee rate (basis points)
(define-constant min-order-amount u1) ;; Minimum 1 credit per order
(define-constant max-order-lifetime u8760) ;; Max 1 week lifetime in blocks
(define-constant basis-points u10000) ;; For percentage calculations

;; Order types
(define-constant order-type-buy u1)
(define-constant order-type-sell u2)

;; Order status
(define-constant order-status-active u1)
(define-constant order-status-filled u2)
(define-constant order-status-cancelled u3)
(define-constant order-status-expired u4)

;; Contract state variables
(define-data-var marketplace-paused bool false)
(define-data-var trading-fee-rate uint u50) ;; 0.5% trading fee (basis points)
(define-data-var total-orders uint u0)
(define-data-var total-volume-traded uint u0)
(define-data-var total-fees-collected uint u0)
(define-data-var min-order-size uint u1)
(define-data-var order-expiry-blocks uint u1440) ;; Default 24 hours

;; Fee distribution
(define-data-var treasury-address principal contract-owner)
(define-data-var fee-treasury-rate uint u7000) ;; 70% to treasury
(define-data-var fee-stakers-rate uint u3000) ;; 30% to stakers

;; Order book data structure
(define-map orders uint {
    maker: principal,
    order-type: uint, ;; 1 = buy, 2 = sell
    amount: uint,
    price-per-credit: uint, ;; Price in microSTX per credit
    total-value: uint,
    filled-amount: uint,
    status: uint,
    created-at-block: uint,
    expires-at-block: uint,
    energy-type-filter: (optional uint), ;; Optional filter for specific energy types
    min-producer-rating: (optional uint) ;; Optional minimum producer rating
})

;; Trade execution records
(define-map trades uint {
    buyer: principal,
    seller: principal,
    buy-order-id: uint,
    sell-order-id: uint,
    amount: uint,
    price-per-credit: uint,
    total-value: uint,
    trading-fee: uint,
    executed-at-block: uint,
    energy-type: uint
})

;; User trading statistics
(define-map user-stats principal {
    total-bought: uint,
    total-sold: uint,
    total-volume: uint,
    orders-created: uint,
    successful-trades: uint,
    reputation-score: uint,
    last-activity-block: uint
})

;; Market maker rewards
(define-map market-maker-rewards principal uint)

;; Active order tracking (for efficient querying)
(define-map active-buy-orders uint bool)
(define-map active-sell-orders uint bool)

;; Price history for market data
(define-map price-history uint {
    stacks-block-height: uint,
    average-price: uint,
    volume: uint,
    num-trades: uint
})

;; State tracking
(define-data-var next-order-id uint u1)
(define-data-var next-trade-id uint u1)
(define-data-var price-history-index uint u1)

;; Order Management Functions

(define-public (create-buy-order 
    (amount uint) 
    (price-per-credit uint) 
    (expiry-blocks uint)
    (energy-type-filter (optional uint))
)
    (let (
        (order-id (var-get next-order-id))
        (total-cost (+ (* amount price-per-credit) (calculate-trading-fee (* amount price-per-credit))))
        (buyer tx-sender)
    )
        (asserts! (not (var-get marketplace-paused)) err-marketplace-paused)
        (asserts! (>= amount (var-get min-order-size)) err-invalid-amount)
        (asserts! (> price-per-credit u0) err-invalid-price)
        (asserts! (<= expiry-blocks (var-get order-expiry-blocks)) err-order-expired)
        
        ;; Check if buyer has enough STX balance (simplified - in reality would check STX balance)
        (asserts! (> total-cost u0) err-insufficient-balance)
        
        ;; Create the buy order
        (map-set orders order-id {
            maker: buyer,
            order-type: order-type-buy,
            amount: amount,
            price-per-credit: price-per-credit,
            total-value: (* amount price-per-credit),
            filled-amount: u0,
            status: order-status-active,
            created-at-block: stacks-block-height,
            expires-at-block: (+ stacks-block-height expiry-blocks),
            energy-type-filter: energy-type-filter,
            min-producer-rating: none
        })
        
        ;; Add to active orders tracking
        (map-set active-buy-orders order-id true)
        
        ;; Update user stats
        (update-user-stats-order-created buyer)
        
        ;; Increment counters
        (var-set next-order-id (+ order-id u1))
        (var-set total-orders (+ (var-get total-orders) u1))
        
        (ok order-id)
    )
)

(define-public (create-sell-order 
    (amount uint) 
    (price-per-credit uint) 
    (expiry-blocks uint)
)
    (let (
        (order-id (var-get next-order-id))
        (seller tx-sender)
    )
        (asserts! (not (var-get marketplace-paused)) err-marketplace-paused)
        (asserts! (>= amount (var-get min-order-size)) err-invalid-amount)
        (asserts! (> price-per-credit u0) err-invalid-price)
        (asserts! (<= expiry-blocks (var-get order-expiry-blocks)) err-order-expired)
        
        ;; Check if seller has enough energy credits
        (asserts! (>= (unwrap-panic (contract-call? energy-credits-contract get-balance seller)) amount) err-insufficient-balance)
        
        ;; Create the sell order
        (map-set orders order-id {
            maker: seller,
            order-type: order-type-sell,
            amount: amount,
            price-per-credit: price-per-credit,
            total-value: (* amount price-per-credit),
            filled-amount: u0,
            status: order-status-active,
            created-at-block: stacks-block-height,
            expires-at-block: (+ stacks-block-height expiry-blocks),
            energy-type-filter: none,
            min-producer-rating: none
        })
        
        ;; Add to active orders tracking
        (map-set active-sell-orders order-id true)
        
        ;; Update user stats
        (update-user-stats-order-created seller)
        
        ;; Increment counters
        (var-set next-order-id (+ order-id u1))
        (var-set total-orders (+ (var-get total-orders) u1))
        
        (ok order-id)
    )
)

;; Trade Execution Functions

(define-public (fill-buy-order (buy-order-id uint) (amount-to-fill uint))
    (let (
        (buy-order (unwrap! (map-get? orders buy-order-id) err-order-not-found))
        (seller tx-sender)
        (buyer (get maker buy-order))
        (remaining-amount (- (get amount buy-order) (get filled-amount buy-order)))
        (fill-amount (if (> amount-to-fill remaining-amount) remaining-amount amount-to-fill))
        (trade-value (* fill-amount (get price-per-credit buy-order)))
        (trading-fee (calculate-trading-fee trade-value))
        (trade-id (var-get next-trade-id))
    )
        (asserts! (not (var-get marketplace-paused)) err-marketplace-paused)
        (asserts! (is-eq (get order-type buy-order) order-type-buy) err-invalid-order-type)
        (asserts! (is-eq (get status buy-order) order-status-active) err-order-already-filled)
        (asserts! (not (is-eq seller buyer)) err-cannot-fill-own-order)
        (asserts! (> fill-amount u0) err-invalid-amount)
        (asserts! (< stacks-block-height (get expires-at-block buy-order)) err-order-expired)
        
        ;; Check seller has enough energy credits
        (asserts! (>= (unwrap-panic (contract-call? energy-credits-contract get-balance seller)) fill-amount) err-insufficient-balance)
        
        ;; Transfer energy credits from seller to buyer
        (try! (contract-call? energy-credits-contract transfer fill-amount seller buyer none))
        
        ;; Record the trade
        (map-set trades trade-id {
            buyer: buyer,
            seller: seller,
            buy-order-id: buy-order-id,
            sell-order-id: u0, ;; Market order
            amount: fill-amount,
            price-per-credit: (get price-per-credit buy-order),
            total-value: trade-value,
            trading-fee: trading-fee,
            executed-at-block: stacks-block-height,
            energy-type: u1 ;; Default energy type
        })
        
        ;; Update buy order with filled amount
        (let (
            (new-filled-amount (+ (get filled-amount buy-order) fill-amount))
            (new-status (if (is-eq new-filled-amount (get amount buy-order)) order-status-filled order-status-active))
        )
            (map-set orders buy-order-id (merge buy-order {
                filled-amount: new-filled-amount,
                status: new-status
            }))
            
            ;; Remove from active orders if fully filled
            (if (is-eq new-status order-status-filled)
                (map-delete active-buy-orders buy-order-id)
                true
            )
        )
        
        ;; Update user statistics
        (update-user-stats-trade buyer seller fill-amount trade-value)
        
        ;; Update global statistics
        (var-set total-volume-traded (+ (var-get total-volume-traded) trade-value))
        (var-set total-fees-collected (+ (var-get total-fees-collected) trading-fee))
        (var-set next-trade-id (+ trade-id u1))
        
        ;; Update price history
        (update-price-history (get price-per-credit buy-order) fill-amount)
        
        (ok trade-id)
    )
)

(define-public (fill-sell-order (sell-order-id uint) (amount-to-fill uint))
    (let (
        (sell-order (unwrap! (map-get? orders sell-order-id) err-order-not-found))
        (buyer tx-sender)
        (seller (get maker sell-order))
        (remaining-amount (- (get amount sell-order) (get filled-amount sell-order)))
        (fill-amount (if (> amount-to-fill remaining-amount) remaining-amount amount-to-fill))
        (trade-value (* fill-amount (get price-per-credit sell-order)))
        (trading-fee (calculate-trading-fee trade-value))
        (trade-id (var-get next-trade-id))
    )
        (asserts! (not (var-get marketplace-paused)) err-marketplace-paused)
        (asserts! (is-eq (get order-type sell-order) order-type-sell) err-invalid-order-type)
        (asserts! (is-eq (get status sell-order) order-status-active) err-order-already-filled)
        (asserts! (not (is-eq buyer seller)) err-cannot-fill-own-order)
        (asserts! (> fill-amount u0) err-invalid-amount)
        (asserts! (< stacks-block-height (get expires-at-block sell-order)) err-order-expired)
        
        ;; Transfer energy credits from seller to buyer
        (try! (contract-call? energy-credits-contract transfer fill-amount seller buyer none))
        
        ;; Record the trade
        (map-set trades trade-id {
            buyer: buyer,
            seller: seller,
            buy-order-id: u0, ;; Market order
            sell-order-id: sell-order-id,
            amount: fill-amount,
            price-per-credit: (get price-per-credit sell-order),
            total-value: trade-value,
            trading-fee: trading-fee,
            executed-at-block: stacks-block-height,
            energy-type: u1 ;; Default energy type
        })
        
        ;; Update sell order with filled amount
        (let (
            (new-filled-amount (+ (get filled-amount sell-order) fill-amount))
            (new-status (if (is-eq new-filled-amount (get amount sell-order)) order-status-filled order-status-active))
        )
            (map-set orders sell-order-id (merge sell-order {
                filled-amount: new-filled-amount,
                status: new-status
            }))
            
            ;; Remove from active orders if fully filled
            (if (is-eq new-status order-status-filled)
                (map-delete active-sell-orders sell-order-id)
                true
            )
        )
        
        ;; Update user statistics
        (update-user-stats-trade buyer seller fill-amount trade-value)
        
        ;; Update global statistics
        (var-set total-volume-traded (+ (var-get total-volume-traded) trade-value))
        (var-set total-fees-collected (+ (var-get total-fees-collected) trading-fee))
        (var-set next-trade-id (+ trade-id u1))
        
        ;; Update price history
        (update-price-history (get price-per-credit sell-order) fill-amount)
        
        (ok trade-id)
    )
)

;; Order Management

(define-public (cancel-order (order-id uint))
    (let (
        (order (unwrap! (map-get? orders order-id) err-order-not-found))
    )
        (asserts! (is-eq tx-sender (get maker order)) err-unauthorized)
        (asserts! (is-eq (get status order) order-status-active) err-order-already-filled)
        
        ;; Update order status to cancelled
        (map-set orders order-id (merge order { status: order-status-cancelled }))
        
        ;; Remove from active orders tracking
        (if (is-eq (get order-type order) order-type-buy)
            (map-delete active-buy-orders order-id)
            (map-delete active-sell-orders order-id)
        )
        
        (ok true)
    )
)

;; Utility Functions

(define-private (calculate-trading-fee (trade-value uint))
    (/ (* trade-value (var-get trading-fee-rate)) basis-points)
)

(define-private (update-user-stats-order-created (user principal))
    (let (
        (current-stats (default-to { 
            total-bought: u0, 
            total-sold: u0, 
            total-volume: u0, 
            orders-created: u0, 
            successful-trades: u0, 
            reputation-score: u100, 
            last-activity-block: u0 
        } (map-get? user-stats user)))
    )
        (map-set user-stats user (merge current-stats {
            orders-created: (+ (get orders-created current-stats) u1),
            last-activity-block: stacks-block-height
        }))
    )
)

(define-private (update-user-stats-trade (buyer principal) (seller principal) (amount uint) (value uint))
    (begin
        ;; Update buyer stats
        (let (
            (buyer-stats (default-to { 
                total-bought: u0, 
                total-sold: u0, 
                total-volume: u0, 
                orders-created: u0, 
                successful-trades: u0, 
                reputation-score: u100, 
                last-activity-block: u0 
            } (map-get? user-stats buyer)))
        )
            (map-set user-stats buyer (merge buyer-stats {
                total-bought: (+ (get total-bought buyer-stats) amount),
                total-volume: (+ (get total-volume buyer-stats) value),
                successful-trades: (+ (get successful-trades buyer-stats) u1),
                last-activity-block: stacks-block-height
            }))
        )
        
        ;; Update seller stats
        (let (
            (seller-stats (default-to { 
                total-bought: u0, 
                total-sold: u0, 
                total-volume: u0, 
                orders-created: u0, 
                successful-trades: u0, 
                reputation-score: u100, 
                last-activity-block: u0 
            } (map-get? user-stats seller)))
        )
            (map-set user-stats seller (merge seller-stats {
                total-sold: (+ (get total-sold seller-stats) amount),
                total-volume: (+ (get total-volume seller-stats) value),
                successful-trades: (+ (get successful-trades seller-stats) u1),
                last-activity-block: stacks-block-height
            }))
        )
    )
)

(define-private (update-price-history (price uint) (volume uint))
    (let (
        (history-id (var-get price-history-index))
        (current-block-data (default-to {
            stacks-block-height: stacks-block-height,
            average-price: u0,
            volume: u0,
            num-trades: u0
        } (map-get? price-history history-id)))
    )
        (if (is-eq (get stacks-block-height current-block-data) stacks-block-height)
            ;; Update existing block data
            (let (
                (new-volume (+ (get volume current-block-data) volume))
                (new-trades (+ (get num-trades current-block-data) u1))
                (new-avg-price (/ (+ (* (get average-price current-block-data) (get num-trades current-block-data)) price) new-trades))
            )
                (map-set price-history history-id {
                    stacks-block-height: stacks-block-height,
                    average-price: new-avg-price,
                    volume: new-volume,
                    num-trades: new-trades
                })
            )
            ;; Create new block data
            (begin
                (map-set price-history history-id {
                    stacks-block-height: stacks-block-height,
                    average-price: price,
                    volume: volume,
                    num-trades: u1
                })
                (var-set price-history-index (+ history-id u1))
            )
        )
    )
)

;; Read-only functions

(define-read-only (get-order (order-id uint))
    (map-get? orders order-id)
)

(define-read-only (get-trade (trade-id uint))
    (map-get? trades trade-id)
)

(define-read-only (get-user-stats (user principal))
    (map-get? user-stats user)
)

(define-read-only (get-marketplace-stats)
    {
        total-orders: (var-get total-orders),
        total-volume-traded: (var-get total-volume-traded),
        total-fees-collected: (var-get total-fees-collected),
        trading-fee-rate: (var-get trading-fee-rate),
        marketplace-paused: (var-get marketplace-paused),
        next-order-id: (var-get next-order-id),
        next-trade-id: (var-get next-trade-id)
    }
)

(define-read-only (get-price-history (history-id uint))
    (map-get? price-history history-id)
)

(define-read-only (is-order-active (order-id uint))
    (let (
        (order (map-get? orders order-id))
    )
        (match order
            some-order (and 
                (is-eq (get status some-order) order-status-active)
                (< stacks-block-height (get expires-at-block some-order))
            )
            false
        )
    )
)

;; Administrative functions

(define-public (pause-marketplace)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set marketplace-paused true)
        (ok true)
    )
)

(define-public (unpause-marketplace)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set marketplace-paused false)
        (ok true)
    )
)

(define-public (set-trading-fee-rate (new-rate uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (<= new-rate max-fee-rate) err-invalid-fee-rate)
        (var-set trading-fee-rate new-rate)
        (ok true)
    )
)

(define-public (set-min-order-size (new-size uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (>= new-size u1) err-invalid-amount)
        (var-set min-order-size new-size)
        (ok true)
    )
)
