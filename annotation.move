module annota_lens::annotation {
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use sui::event;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use std::option::{Self, Option};

    // ====== Constants ======
    const MIN_STAKE: u64 = 1_000_000; // 1 SUI
    const PARTIAL_BURN_PERCENTAGE: u64 = 50; // 50% burn for non-valuable annotations
    const REWARD_MULTIPLIER: u64 = 2; // 2x reward for valuable annotations
    
    // ====== Error Codes ======
    const EInsufficientStake: u64 = 0;
    const EInvalidPrice: u64 = 1;
    const ENotOwner: u64 = 2;
    const EIncorrectPayment: u64 = 3;
    const ENotForSale: u64 = 4;
    const EAlreadyValidated: u64 = 5;

    // ====== Events ======
    public struct AnnotationSubmitted has drop, copy {
        id: ID,
        creator: address,
        stake_amount: u64
    }

    public struct AnnotationValidated has drop, copy {
        id: ID,
        is_valuable: bool,
        reward_amount: u64
    }

    public struct NFTMinted has drop, copy {
        id: ID,
        creator: address,
        metadata_hash: vector<u8>
    }

    public struct NFTListed has drop, copy {
        id: ID,
        price: u64
    }

    public struct NFTSold has drop, copy {
        id: ID,
        seller: address,
        buyer: address,
        price: u64
    }

    // ====== Core Objects ======
    public struct ValuableAnnotationNFT has key, store {
        id: UID,
        creator: address,
        metadata_hash: vector<u8>,
        created_at: u64,
        stake_amount: u64,
        reward_amount: u64,
        ai_comparison_score: u64,
        for_sale: bool,
        price: Option<u64>
    }

    public struct AnnotationSubmission has key, store {
        id: UID,
        creator: address,
        data_hash: vector<u8>,
        label_hash: vector<u8>,
        submitted_at: u64,
        validated: bool,
        stake: Balance<SUI>
    }

    public struct AnnotaLensApp has key {
        id: UID,
        submissions: Table<ID, AnnotationSubmission>,
        stake_pool: Balance<SUI>,
        burn_pool: Balance<SUI>,
        nft_listings: Table<ID, u64>,
        total_annotations: u64,
        total_valuable: u64
    }

    // ====== Core Functions ======
    
    fun init(ctx: &mut TxContext) {
        let app = AnnotaLensApp {
            id: object::new(ctx),
            submissions: table::new(ctx),
            stake_pool: balance::zero(),
            burn_pool: balance::zero(),
            nft_listings: table::new(ctx),
            total_annotations: 0,
            total_valuable: 0
        };
        transfer::share_object(app);
    }

    public entry fun submit_annotation(
        app: &mut AnnotaLensApp,
        stake_coin: Coin<SUI>,
        data_hash: vector<u8>,
        label_hash: vector<u8>,
        ctx: &mut TxContext
    ) {
        // Verify minimum stake
        let stake_amount = coin::value(&stake_coin);
        assert!(stake_amount >= MIN_STAKE, EInsufficientStake);
        
        // Convert coin to balance
        let stake = coin::into_balance(stake_coin);
        
        let submission = AnnotationSubmission {
            id: object::new(ctx),
            creator: tx_context::sender(ctx),
            data_hash,
            label_hash,
            submitted_at: tx_context::epoch(ctx),
            validated: false,
            stake
        };

        let id = object::uid_to_inner(&submission.id);
        table::add(&mut app.submissions, id, submission);
        app.total_annotations = app.total_annotations + 1;

        event::emit(AnnotationSubmitted {
            id,
            creator: tx_context::sender(ctx),
            stake_amount
        });
    }

    public entry fun validate_annotation(
        app: &mut AnnotaLensApp,
        submission_id: ID,
        is_valuable: bool,
        ai_comparison_score: u64,
        metadata_hash: vector<u8>,
        ctx: &mut TxContext
    ) {
        let submission = table::borrow_mut(&mut app.submissions, submission_id);
        assert!(!submission.validated, EAlreadyValidated);

	submission.validated = true;

        let stake_amount = balance::value(&submission.stake);
        let creator = submission.creator;

        if (is_valuable) {
            // Calculate reward
            let reward_amount = stake_amount * REWARD_MULTIPLIER;
            
            // Mint NFT
            let nft = ValuableAnnotationNFT {
                id: object::new(ctx),
                creator,
                metadata_hash,
                created_at: tx_context::epoch(ctx),
                stake_amount,
                reward_amount,
                ai_comparison_score,
                for_sale: false,
                price: option::none()
            };

            // Transfer NFT to creator
            transfer::public_transfer(nft, creator);
            
            // Return stake + reward
            let reward_coin = coin::from_balance(
                balance::split(&mut app.stake_pool, reward_amount),
                ctx
            );
            transfer::public_transfer(reward_coin, creator);
            
            app.total_valuable = app.total_valuable + 1;
        } else {
            // Partial burn of stake
            let burn_amount = (stake_amount * PARTIAL_BURN_PERCENTAGE) / 100;
            let return_amount = stake_amount - burn_amount;
            
            // Return remaining stake to creator
            let return_coin = coin::from_balance(
                balance::split(&mut submission.stake, return_amount),
                ctx
            );
            transfer::public_transfer(return_coin, creator);
            
            // Move remaining stake to burn pool
            balance::join(&mut app.burn_pool, balance::withdraw_all(&mut submission.stake));
        };

        event::emit(AnnotationValidated {
            id: submission_id,
            is_valuable,
            reward_amount: if (is_valuable) { stake_amount * REWARD_MULTIPLIER } else { 0 }
        });
    }

    // ====== Marketplace Functions ======
    
    public entry fun list_nft(
        app: &mut AnnotaLensApp,
        nft: &mut ValuableAnnotationNFT,
        price: u64,
        ctx: &TxContext
    ) {
        assert!(nft.creator == tx_context::sender(ctx), ENotOwner);
        assert!(price > 0, EInvalidPrice);
        
        nft.for_sale = true;
        nft.price = option::some(price);
        
        let nft_id = object::uid_to_inner(&nft.id);
        table::add(&mut app.nft_listings, nft_id, price);

        event::emit(NFTListed {
            id: nft_id,
            price
        });
    }

    public entry fun purchase_nft(
        app: &mut AnnotaLensApp,
        nft: &mut ValuableAnnotationNFT,
        payment: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        let nft_id = object::uid_to_inner(&nft.id);
        assert!(nft.for_sale, ENotForSale);
        
        let price = *table::borrow(&app.nft_listings, nft_id);
        assert!(coin::value(&payment) == price, EIncorrectPayment);

        // Process payment
        balance::join(&mut app.stake_pool, coin::into_balance(payment));
        
        // Update NFT
        nft.for_sale = false;
        nft.price = option::none();
        
        // Remove listing
        table::remove(&mut app.nft_listings, nft_id);

        event::emit(NFTSold {
            id: nft_id,
            seller: nft.creator,
            buyer: tx_context::sender(ctx),
            price
        });
    }

    // ====== View Functions ======
    
    public fun get_stats(app: &AnnotaLensApp): (u64, u64) {
        (app.total_annotations, app.total_valuable)
    }

    public fun get_nft_details(
        nft: &ValuableAnnotationNFT
    ): (address, vector<u8>, u64, u64, u64, bool, Option<u64>) {
        (
            nft.creator,
            nft.metadata_hash,
            nft.stake_amount,
            nft.reward_amount,
            nft.ai_comparison_score,
            nft.for_sale,
            nft.price
        )
    }
}
