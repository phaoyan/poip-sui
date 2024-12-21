#[allow(lint(self_transfer))]
module poip_sui::knowledge_product {
    use sui::coin::{Self};
    use sui::sui::SUI;
    use sui::event;
    use std::string::{String};
    use sui::balance::{Self, Balance};

    // Errors
    const ENotCreator: u64 = 0;
    const EInsufficientPayment: u64 = 1;
    const EGoalCountShouldGreaterThanZero: u64 = 2;
    const EInvalidDecryptionRequest: u64 = 3;
    const ECompensationAlreadyClaimed: u64 = 4;
    const EProductAlreadyPublicized: u64 = 5;
    const EMaxCountShouldGTEGoalCount: u64 = 6;
    const EOverWithrdaw: u64 = 7;
    const EInsufficientContractBalance: u64 = 8;
    const ENotBuyer: u64 = 9;
    const EPriceShouldGreaterThanZero: u64 = 10;

    // Events
    public struct PurchaseEvent has copy, drop {
        product_id: address,
        buyer: address,
        price: u64,
    }

    public struct CompensationClaimedEvent has copy, drop {
        product_id: address,
        buyer: address,
        amount: u64,
    }

    public struct PublicizedEvent has copy, drop {
        product_id: address,
    }

    // Structs
    public struct KnowledgeProduct has key {
        id: UID,
        creator: address,
        price: u64,
        goal_count: u64,
        max_count: u64,
        buyer_count: u64,
        metadata: String,
        storage_link: String,
        encrypted_key: EncryptedKey,
        publicized: bool,
        balance: Balance<SUI>,
    }

    public struct PurchaseRecord has key {
        id: UID,
        product_id: address,
        buyer: address,
        paid_amount: u64,
        compensation_claimed: u64,
    }

    public struct EncryptedKey has store {
        data: vector<u8>,
    }

    public struct KeyCapability has key, store {
        id: UID,
        product_id: address, 
    }

    public struct DecryptionRequest has key {
        id: UID,
        product_id: address,
        buyer: address,
    }

    fun init(_ctx: &mut TxContext) {}

    // Creator Functions
    public fun create_knowledge_product(
        creator: address,
        price: u64,
        goal_count: u64,
        max_count: u64,
        metadata: String,
        storage_link: String,
        encrypted_key_data: vector<u8>,
        ctx: &mut TxContext
    ) {
        assert!(price >  0, EPriceShouldGreaterThanZero);
        assert!(goal_count >  0, EGoalCountShouldGreaterThanZero);
        assert!(max_count  >= goal_count, EMaxCountShouldGTEGoalCount);
        
        let encrypted_key = EncryptedKey { data: encrypted_key_data };

        let knowledge_product = KnowledgeProduct {
            id: object::new(ctx),
            creator,
            price,
            goal_count,
            max_count,
            buyer_count: 0,
            metadata,
            storage_link,
            encrypted_key,
            publicized: false,
            balance: balance::zero(),
        };

        transfer::transfer(knowledge_product, creator);
    }

    // Buyer Functions
    public fun purchase(
        product: &mut KnowledgeProduct,
        payment: &mut Balance<SUI>,
        buyer: address,
        ctx: &mut TxContext
    ) {
        assert!(!product.publicized, EProductAlreadyPublicized);
        assert!(balance::value(payment) >= product.price, EInsufficientPayment);
        // Increase the buyer count
        product.buyer_count = product.buyer_count + 1;
        // Create a PurchaseRecord object
        let purchase_record = PurchaseRecord {
            id: object::new(ctx),
            product_id: object::uid_to_address(&product.id),
            buyer,
            paid_amount: product.price,
            compensation_claimed: 0,
        };
        transfer::transfer(purchase_record, buyer);
        // Create a DecryptionRequest object and transfer it to the buyer
        let decryption_request = DecryptionRequest {
            id: object::new(ctx),
            product_id: object::uid_to_address(&product.id),
            buyer,
        };
        transfer::transfer(decryption_request, buyer);
        // Emit a PurchaseEvent
        event::emit(PurchaseEvent {
            product_id: object::uid_to_address(&product.id),
            buyer,
            price: product.price,
        });
        // Transfer the payment to the creator (in a real scenario, you might want to handle fees etc.)
        let real_pay = balance::split(payment, product.price);
        balance::join(&mut product.balance, real_pay);

        if(product.buyer_count >= product.max_count) {
            publicize(product, ctx)
        }
    }

    public fun withdraw(
        creator_balance: &mut balance::Balance<SUI>,
        product: &mut KnowledgeProduct,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(product.creator == tx_context::sender(ctx), ENotCreator);
        assert!(amount <= product.price * product.max_count, EOverWithrdaw);
        assert!(balance::value(&product.balance) >= amount, EInsufficientContractBalance);

        // Take the specified amount from the contract balance
        let payment = balance::split(&mut product.balance, amount);
        creator_balance.join(payment);
    }

    public fun grant_key_access(
        product: &KnowledgeProduct,
        request: DecryptionRequest,
        ctx: &mut TxContext
    ) {
        assert!(request.product_id == object::uid_to_address(&product.id), EInvalidDecryptionRequest);
        assert!(request.buyer == tx_context::sender(ctx), EInvalidDecryptionRequest);

        // Transfer the KeyCapability to the request sender (the buyer)
        let key_capability = KeyCapability { 
            id: object::new(ctx), 
            product_id: object::uid_to_address(&product.id) 
        };
        transfer::transfer(key_capability, tx_context::sender(ctx));

        // Destroy the DecryptionRequest object as it has been used
        let DecryptionRequest { id, product_id: _, buyer: _ } = request;
        object::delete(id);
    }

    public fun get_encrypted_key(
        product: &KnowledgeProduct,
        capability: &KeyCapability
    ): &EncryptedKey {
        // 验证 KeyCapability 的 product_id 是否与当前 KnowledgeProduct 的 ID 匹配
        assert!(capability.product_id == object::uid_to_address(&product.id), EInvalidDecryptionRequest);
        &product.encrypted_key
    }

    public fun claim_compensation(
        product: &mut KnowledgeProduct,
        record: &mut PurchaseRecord,
        ctx: &mut TxContext
    ) {
        assert!(record.buyer == tx_context::sender(ctx), ENotBuyer);
        let current_compensation = calculate_compensation(product);
        let amount_to_claim = current_compensation - record.compensation_claimed;
        assert!(amount_to_claim > 0, ECompensationAlreadyClaimed);
        assert!(balance::value(&product.balance) >= amount_to_claim, EInsufficientPayment); // 确保合约有足够的余额
        
        let compensation_coin = coin::take<SUI>(&mut product.balance, amount_to_claim, ctx);
        transfer::public_transfer(compensation_coin, record.buyer);
        record.compensation_claimed = current_compensation;

        event::emit(CompensationClaimedEvent {
            product_id: object::uid_to_address(&product.id),
            buyer: record.buyer,
            amount: amount_to_claim,
        });
    }

    // Publicization Function
    fun publicize(
        product: &mut KnowledgeProduct,
        _ctx: &mut TxContext
    ) {
        assert!(!product.publicized, EProductAlreadyPublicized);
        if (product.buyer_count >= product.max_count) {
            product.publicized = true;
            event::emit(PublicizedEvent { product_id: object::uid_to_address(&product.id) });
            // Optionally, you could trigger actions like making the encrypted_key publicly available
            // but this would require careful consideration of the security implications.
        }
    }

    public fun calculate_compensation(product: &KnowledgeProduct): u64 {
        if (product.buyer_count <= product.goal_count) { 0 } 
        else {
            let total_paid = product.buyer_count * product.price;
            let excess = total_paid - product.price * product.goal_count;
            excess / product.buyer_count
        }
    }



    #[test]
    fun test_create_knowledge_product() {
        use sui::test_scenario;
        use std::string;
        
        let creator = @0xCAFE;

        let test_price: u64 = 10;
        let test_goal_count: u64 = 10;
        let test_max_count: u64 = 20;
        let metadata = string::utf8(b"Test Metadata");
        let storage_link = string::utf8(b"ipfs://test");
        let encrypted_key_data: vector<u8> = vector::singleton(1);

        let mut scenario  = test_scenario::begin(creator);
        {
            init(scenario.ctx());
        };
        scenario.next_tx(creator);
        {
            create_knowledge_product(
                creator,
                test_price,
                test_goal_count,
                test_max_count,
                metadata,
                storage_link,
                encrypted_key_data,
                scenario.ctx()
            );
        };
        scenario.next_tx(creator);
        {
            let product = test_scenario::take_from_sender<KnowledgeProduct>(&scenario);
            assert!(product.price == test_price, 400);
            assert!(product.goal_count == test_goal_count, 401);
            assert!(product.max_count == test_max_count, 402);
            assert!(product.buyer_count == 0, 403);
            assert!(!product.publicized, 404);
            scenario.return_to_sender(product);
        };
        scenario.next_tx(creator);
        
        test_scenario::end(scenario);
    }

    #[test]
    fun test_purchase_success() {
        use sui::test_scenario;
        use std::string;

        let creator = @0xCAFE;
        let buyer = @0xBEEF;
        let test_price: u64 = 10;
        let test_goal_count: u64 = 10;
        let test_max_count: u64 = 20;
        let metadata = string::utf8(b"Test Metadata");
        let storage_link = string::utf8(b"ipfs://test");
        let encrypted_key_data: vector<u8> = vector::singleton(1);

        let mut scenario = test_scenario::begin(creator);
        let product_id: address;
        {
            init(scenario.ctx());
        };
        scenario.next_tx(creator);
        {
            create_knowledge_product(
                creator,
                test_price,
                test_goal_count,
                test_max_count,
                metadata,
                storage_link,
                encrypted_key_data,
                scenario.ctx()
            );
        };
        scenario.next_tx(buyer);
        {
            let mut product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            product_id = object::uid_to_address(&product.id);
            let balance = 20;
            let mut payment = balance::create_for_testing(balance);
            purchase(
                &mut product,
                &mut payment,
                buyer,
                scenario.ctx()
            );
            assert!(product.buyer_count == 1, 500);
            assert!(payment.value() == balance - test_price, 501);
            test_scenario::return_to_address(creator, product);
            payment.destroy_for_testing();
        };
        scenario.next_tx(buyer);
        {
            let record = test_scenario::take_from_sender<PurchaseRecord>(&scenario);
            assert!(record.paid_amount == test_price, 502);
            assert!(record.buyer == buyer, 503);
            assert!(record.product_id == product_id, 504);
            scenario.return_to_sender(record);
            let request = test_scenario::take_from_sender<DecryptionRequest>(&scenario);
            assert!(request.buyer == buyer, 505);
            assert!(request.product_id == product_id, 506);
            scenario.return_to_sender(request);
        };
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure]
    fun test_purchase_fail_for_inefficient_balance() {
        use sui::test_scenario;
        use std::string;

        let creator = @0xCAFE;
        let buyer = @0xBEEF;
        let test_price: u64 = 10;
        let test_goal_count: u64 = 10;
        let test_max_count: u64 = 20;
        let metadata = string::utf8(b"Test Metadata");
        let storage_link = string::utf8(b"ipfs://test");
        let encrypted_key_data: vector<u8> = vector::singleton(1);

        let mut scenario = test_scenario::begin(creator);
        {
            init(scenario.ctx());
        };
        scenario.next_tx(creator);
        {
            create_knowledge_product(
                creator,
                test_price,
                test_goal_count,
                test_max_count,
                metadata,
                storage_link,
                encrypted_key_data,
                scenario.ctx()
            );
        };
        scenario.next_tx(buyer);
        {
            let mut product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            let mut payment = balance::create_for_testing(1);
            purchase(
                &mut product,
                &mut payment,
                buyer,
                scenario.ctx()
            );
            assert!(product.buyer_count == 1, 500);
            test_scenario::return_to_address(creator, product);
            payment.destroy_for_testing();
        };
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure]
    fun test_withdraw_not_creator() {
        use sui::test_scenario;
        use std::string;

        let creator = @0xCAFE;
        let attacker = @0xBEEF;
        let test_price: u64 = 10;
        let test_goal_count: u64 = 10;
        let test_max_count: u64 = 20;
        let metadata = string::utf8(b"Test Metadata");
        let storage_link = string::utf8(b"ipfs://test");
        let encrypted_key_data: vector<u8> = vector::singleton(1);
        let withdraw_amount: u64 = 5;

        let mut scenario = test_scenario::begin(creator);
        {
            init(scenario.ctx());
        };
        scenario.next_tx(creator);
        {
            create_knowledge_product(
                creator,
                test_price,
                test_goal_count,
                test_max_count,
                metadata,
                storage_link,
                encrypted_key_data,
                scenario.ctx()
            );
        };
        scenario.next_tx(attacker);
        {
            let mut product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            let mut attacker_balance = balance::create_for_testing(100);
            withdraw(&mut attacker_balance, &mut product, withdraw_amount, scenario.ctx());
            test_scenario::return_to_address(creator, product);
            attacker_balance.destroy_for_testing();
        };
        test_scenario::end(scenario);
    }


    #[test]
    #[expected_failure]
    fun test_withdraw_insufficient_balance() {
        use sui::test_scenario;
        use std::string;

        let creator = @0xCAFE;
        let test_price: u64 = 10;
        let test_goal_count: u64 = 10;
        let test_max_count: u64 = 20;
        let metadata = string::utf8(b"Test Metadata");
        let storage_link = string::utf8(b"ipfs://test");
        let encrypted_key_data: vector<u8> = vector::singleton(1);
        let withdraw_amount: u64 = 5;

        let mut scenario = test_scenario::begin(creator);
        {
            init(scenario.ctx());
        };
        scenario.next_tx(creator);
        {
            create_knowledge_product(
                creator,
                test_price,
                test_goal_count,
                test_max_count,
                metadata,
                storage_link,
                encrypted_key_data,
                scenario.ctx()
            );
        };
        scenario.next_tx(creator);
        {
            let mut product = test_scenario::take_from_sender<KnowledgeProduct>(&scenario);
            let mut creator_balance = balance::create_for_testing(100);
            withdraw(&mut creator_balance, &mut product, withdraw_amount, scenario.ctx());
            scenario.return_to_sender(product);
            creator_balance.destroy_for_testing();
        };
        test_scenario::end(scenario);
    }

    #[test]
    fun test_withdraw_success() {
        use sui::test_scenario;
        use std::string;

        let creator = @0xCAFE;
        let buyer = @0xBEEF;
        let test_price: u64 = 10;
        let test_goal_count: u64 = 10;
        let test_max_count: u64 = 20;
        let metadata = string::utf8(b"Test Metadata");
        let storage_link = string::utf8(b"ipfs://test");
        let encrypted_key_data: vector<u8> = vector::singleton(1);
        let withdraw_amount: u64 = 10;

        let mut scenario = test_scenario::begin(creator);
        {
            init(scenario.ctx());
        };
        scenario.next_tx(creator);
        {
            create_knowledge_product(
                creator,
                test_price,
                test_goal_count,
                test_max_count,
                metadata,
                storage_link,
                encrypted_key_data,
                scenario.ctx()
            );
        };
        scenario.next_tx(buyer);
        {
            let mut product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            let mut payment = balance::create_for_testing(10);
            purchase(
                &mut product,
                &mut payment,
                buyer,
                scenario.ctx()
            );
            test_scenario::return_to_address(creator, product);
            payment.destroy_for_testing();
        };
        scenario.next_tx(creator);
        {
            let mut product = test_scenario::take_from_sender<KnowledgeProduct>(&scenario);
            let mut creator_balance = balance::create_for_testing(0);
            withdraw(&mut creator_balance, &mut product, withdraw_amount, scenario.ctx());
            assert!(balance::value(&creator_balance) == withdraw_amount, 600);
            scenario.return_to_sender(product);
            creator_balance.destroy_for_testing();
        };
        test_scenario::end(scenario);
    }

    #[test]
    fun test_grant_key_access_success() {
        use sui::test_scenario;
        use std::string;

        let creator = @0xCAFE;
        let buyer = @0xBEEF;
        let test_price: u64 = 10;
        let test_goal_count: u64 = 10;
        let test_max_count: u64 = 20;
        let metadata = string::utf8(b"Test Metadata");
        let storage_link = string::utf8(b"ipfs://test");
        let encrypted_key_data: vector<u8> = vector::singleton(1);

        let mut scenario = test_scenario::begin(creator);
        {
            init(scenario.ctx());
        };
        scenario.next_tx(creator);
        {
            create_knowledge_product(
                creator,
                test_price,
                test_goal_count,
                test_max_count,
                metadata,
                storage_link,
                encrypted_key_data,
                scenario.ctx()
            );
        };
        scenario.next_tx(buyer);
        {
            let mut product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            let mut payment = balance::create_for_testing(10);
            purchase(
                &mut product,
                &mut payment,
                buyer,
                scenario.ctx()
            );
            test_scenario::return_to_address(creator, product);
            payment.destroy_for_testing();
        };
        scenario.next_tx(buyer);
        {
            let request = test_scenario::take_from_sender<DecryptionRequest>(&scenario);
            let product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            grant_key_access(&product, request, scenario.ctx());
            test_scenario::return_to_address(creator, product);
        };
        scenario.next_tx(buyer);
        {
            assert!(test_scenario::has_most_recent_for_sender<KeyCapability>(&scenario), 700);
            assert!(!test_scenario::has_most_recent_for_sender<DecryptionRequest>(&scenario), 701);
        };
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure]
    fun test_grant_key_access_invalid_request() {
        use sui::test_scenario;
        use std::string;

        let creator = @0xCAFE;
        let attacker = @0xBEEF;
        let test_price: u64 = 10;
        let test_goal_count: u64 = 10;
        let test_max_count: u64 = 20;
        let metadata = string::utf8(b"Test Metadata");
        let storage_link = string::utf8(b"ipfs://test");
        let encrypted_key_data: vector<u8> = vector::singleton(1);

        let mut scenario = test_scenario::begin(creator);
        {
            init(scenario.ctx());
        };
        scenario.next_tx(creator);
        {
            create_knowledge_product(
                creator,
                test_price,
                test_goal_count,
                test_max_count,
                metadata,
                storage_link,
                encrypted_key_data,
                scenario.ctx()
            );
        };
        scenario.next_tx(attacker);
        {
            let product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            let fake_request = DecryptionRequest {
                id: object::new(scenario.ctx()),
                product_id: object::uid_to_address(&product.id),
                buyer: attacker,
            };
            grant_key_access(&product, fake_request, scenario.ctx());
            test_scenario::return_to_sender(&scenario, product);
        };
        test_scenario::end(scenario);
    }

    #[test]
    fun test_get_encrypted_key_success() {
        use sui::test_scenario;
        use std::string;

        let creator = @0xCAFE;
        let buyer = @0xBEEF;
        let test_price: u64 = 10;
        let test_goal_count: u64 = 10;
        let test_max_count: u64 = 20;
        let metadata = string::utf8(b"Test Metadata");
        let storage_link = string::utf8(b"ipfs://test");
        let encrypted_key_data: vector<u8> = vector::singleton(1);

        let mut scenario = test_scenario::begin(creator);
        {
            init(scenario.ctx());
        };
        scenario.next_tx(creator);
        {
            create_knowledge_product(
                creator,
                test_price,
                test_goal_count,
                test_max_count,
                metadata,
                storage_link,
                encrypted_key_data,
                scenario.ctx()
            );
        };
        scenario.next_tx(buyer);
        {
            let mut product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            let mut payment = balance::create_for_testing(10);
            purchase(
                &mut product,
                &mut payment,
                buyer,
                scenario.ctx()
            );
            test_scenario::return_to_address(creator, product);
            payment.destroy_for_testing();
        };
        scenario.next_tx(buyer);
        {
            let request = test_scenario::take_from_sender<DecryptionRequest>(&scenario);
            let product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            grant_key_access(&product, request, scenario.ctx());
            test_scenario::return_to_address(creator, product);
        };
        scenario.next_tx(buyer);
        {
            let product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            let capability = test_scenario::take_from_address<KeyCapability>(&scenario, buyer);
            let encrypted_key = get_encrypted_key(&product, &capability);
            assert!(encrypted_key.data == vector::singleton(1), 800);
            test_scenario::return_to_address(creator, product);
            test_scenario::return_to_sender(&scenario, capability);
        };
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure]
    fun test_get_encrypted_key_invalid_capability() {
        use sui::test_scenario;
        use std::string;

        let creator = @0xCAFE;
        let attacker = @0xBEEF;
        let test_price: u64 = 10;
        let test_goal_count: u64 = 10;
        let test_max_count: u64 = 20;
        let metadata = string::utf8(b"Test Metadata");
        let storage_link = string::utf8(b"ipfs://test");
        let encrypted_key_data: vector<u8> = vector::singleton(1);

        let mut scenario = test_scenario::begin(creator);
        {
            init(scenario.ctx());
        };
        scenario.next_tx(creator);
        {
            create_knowledge_product(
                creator,
                test_price,
                test_goal_count,
                test_max_count,
                metadata,
                storage_link,
                encrypted_key_data,
                scenario.ctx()
            );
        };
        scenario.next_tx(attacker);
        {
            let product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            let fake_capability = KeyCapability{
                id: object::new(scenario.ctx()),
                product_id: object::uid_to_address(&product.id),
            };
            get_encrypted_key(&product, &fake_capability);
            test_scenario::return_to_address(creator, product);
            test_scenario::return_to_address(attacker, fake_capability);
        };
        test_scenario::end(scenario);
    }

    #[test]
    fun test_claim_compensation_success() {
        use sui::test_scenario;
        use std::string;

        let creator = @0xCAFE;
        let buyer = @0xBEEF;
        let next_buyer = @0xBABE;
        let test_price: u64 = 10;
        let test_goal_count: u64 = 1;
        let test_max_count: u64 = 20;
        let metadata = string::utf8(b"Test Metadata");
        let storage_link = string::utf8(b"ipfs://test");
        let encrypted_key_data: vector<u8> = vector::singleton(1);

        let mut scenario = test_scenario::begin(creator);
        {
            init(scenario.ctx());
        };
        scenario.next_tx(creator);
        {
            create_knowledge_product(
                creator,
                test_price,
                test_goal_count,
                test_max_count,
                metadata,
                storage_link,
                encrypted_key_data,
                scenario.ctx()
            );
        };
        scenario.next_tx(buyer);
        {
            let mut product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            let mut payment = balance::create_for_testing(10);
            purchase(
                &mut product,
                &mut payment,
                buyer,
                scenario.ctx()
            );
            test_scenario::return_to_address(creator, product);
            payment.destroy_for_testing();
        };
        scenario.next_tx(buyer);
        {
            let mut product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            let mut payment = balance::create_for_testing(10);
            purchase(
                &mut product,
                &mut payment,
                next_buyer,
                scenario.ctx()
            );
            test_scenario::return_to_address(creator, product);
            payment.destroy_for_testing();
        };
        scenario.next_tx(buyer);
        {
            let mut product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            let mut record = test_scenario::take_from_sender<PurchaseRecord>(&scenario);
            claim_compensation(&mut product, &mut record, scenario.ctx());
            assert!(record.compensation_claimed == test_price / 2, 900);
            assert!(balance::value(&product.balance) == test_price + test_price / 2, 901);
            test_scenario::return_to_address(creator, product);
            scenario.return_to_sender(record);
        };
        scenario.next_tx(next_buyer);
        {
            let mut product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            let mut record = test_scenario::take_from_sender<PurchaseRecord>(&scenario);
            claim_compensation(&mut product, &mut record, scenario.ctx());
            assert!(record.compensation_claimed == test_price / 2, 900);
            assert!(balance::value(&product.balance) == test_price, 901);
            test_scenario::return_to_address(creator, product);
            scenario.return_to_sender(record);
        };
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure]
    fun test_claim_compensation_not_buyer() {
        use sui::test_scenario;
        use std::string;

        let creator = @0xCAFE;
        let buyer = @0xBEEF;
        let attacker = @0xC0DE;
        let test_price: u64 = 10;
        let test_goal_count: u64 = 1;
        let test_max_count: u64 = 20;
        let metadata = string::utf8(b"Test Metadata");
        let storage_link = string::utf8(b"ipfs://test");
        let encrypted_key_data: vector<u8> = vector::singleton(1);

        let mut scenario = test_scenario::begin(creator);
        {
            init(scenario.ctx());
        };
        scenario.next_tx(creator);
        {
            create_knowledge_product(
                creator,
                test_price,
                test_goal_count,
                test_max_count,
                metadata,
                storage_link,
                encrypted_key_data,
                scenario.ctx()
            );
        };
        scenario.next_tx(buyer);
        {
            let mut product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            let mut payment = balance::create_for_testing(10);
            purchase(
                &mut product,
                &mut payment,
                buyer,
                scenario.ctx()
            );
            test_scenario::return_to_address(creator, product);
            payment.destroy_for_testing();
        };
        scenario.next_tx(attacker);
        {
            let mut product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            let mut record = test_scenario::take_from_address<PurchaseRecord>(&scenario, buyer);
            claim_compensation(&mut product, &mut record, scenario.ctx());
            test_scenario::return_to_address(creator, product);
            test_scenario::return_to_sender(&scenario, record);
        };
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure]
    fun test_claim_compensation_already_claimed() {
        use sui::test_scenario;
        use std::string;

        let creator = @0xCAFE;
        let buyer = @0xBEEF;
        let next_buyer = @0xBABE;
        let test_price: u64 = 10;
        let test_goal_count: u64 = 1;
        let test_max_count: u64 = 20;
        let metadata = string::utf8(b"Test Metadata");
        let storage_link = string::utf8(b"ipfs://test");
        let encrypted_key_data: vector<u8> = vector::singleton(1);

        let mut scenario = test_scenario::begin(creator);
        {
            init(scenario.ctx());
        };
        scenario.next_tx(creator);
        {
            create_knowledge_product(
                creator,
                test_price,
                test_goal_count,
                test_max_count,
                metadata,
                storage_link,
                encrypted_key_data,
                scenario.ctx()
            );
        };
        scenario.next_tx(buyer);
        {
            let mut product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            let mut payment = balance::create_for_testing(10);
            purchase(
                &mut product,
                &mut payment,
                buyer,
                scenario.ctx()
            );
            test_scenario::return_to_address(creator, product);
            payment.destroy_for_testing();
        };
        scenario.next_tx(buyer);
        {
            let mut product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            let mut payment = balance::create_for_testing(10);
            purchase(
                &mut product,
                &mut payment,
                next_buyer,
                scenario.ctx()
            );
            test_scenario::return_to_address(creator, product);
            payment.destroy_for_testing();
        };
        scenario.next_tx(buyer);
        {
            let mut product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            let mut record = test_scenario::take_from_sender<PurchaseRecord>(&scenario);
            claim_compensation(&mut product, &mut record, scenario.ctx());
            assert!(record.compensation_claimed == test_price / 2, 900);
            assert!(balance::value(&product.balance) == test_price + test_price / 2, 901);
            test_scenario::return_to_address(creator, product);
            scenario.return_to_sender(record);
        };
        scenario.next_tx(next_buyer);
        {
            let mut product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            let mut record = test_scenario::take_from_sender<PurchaseRecord>(&scenario);
            claim_compensation(&mut product, &mut record, scenario.ctx());
            assert!(record.compensation_claimed == test_price / 2, 900);
            assert!(balance::value(&product.balance) == test_price, 901);
            test_scenario::return_to_address(creator, product);
            scenario.return_to_sender(record);
        };
        scenario.next_tx(buyer);
        {
            let mut product = test_scenario::take_from_address<KnowledgeProduct>(&scenario, creator);
            let mut record = test_scenario::take_from_sender<PurchaseRecord>(&scenario);
            claim_compensation(&mut product, &mut record, scenario.ctx());
            test_scenario::return_to_address(creator, product);
            scenario.return_to_sender(record);
        };
        test_scenario::end(scenario);
    }

}
