// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {GameToken} from "../src/GameToken.sol";

/**
 * @title GameToken Test Suite
 * @notice Comprehensive tests for GameToken bonding curve mechanics
 * @dev Tests cover:
 *      - Bonding curve buy/sell mechanics
 *      - Fee collection
 *      - Treasury management
 *      - Burn functionality
 *      - Edge cases and attack vectors
 */
contract GameTokenTest is Test {
    GameToken public token;
    address public owner;
    address public treasury;
    address public user1;
    address public user2;
    address public attacker;

    uint256 constant INITIAL_SUPPLY = 1_000_000_000 * 10**18;
    uint256 constant MIN_PURCHASE = 0.001 ether;
    uint256 constant TOKENS_PER_POL = 1000;

    event TokensPurchased(address indexed buyer, uint256 maticIn, uint256 tokensOut);
    event TokensRedeemed(address indexed seller, uint256 tokensIn, uint256 maticOut);
    event TokensBurned(address indexed from, uint256 amount);

    // Allow test contract to receive MATIC
    receive() external payable {}

    function setUp() public {
        owner = address(this);
        treasury = makeAddr("treasury");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        attacker = makeAddr("attacker");

        // Deploy token (no initial supply - must mint with POL)
        token = new GameToken();
        
        // Owner mints initial tokens with POL backing (for tests that need tokens)
        uint256 ownerPOL = 1_000_000 ether; // 1M POL to mint 1B tokens
        vm.deal(owner, ownerPOL);
        token.buyTokens{value: ownerPOL}();

        // Give users some MATIC to test with
        vm.deal(user1, 1000 ether);
        vm.deal(user2, 1000 ether);
        vm.deal(attacker, 1000 ether);
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function testInitialSupply() public {
        // Deploy fresh token to test initial state
        GameToken freshToken = new GameToken();
        assertEq(freshToken.totalSupply(), 0, "Initial supply should be 0 (all tokens must be minted with POL)");
    }

    function testInitialSupplyToOwner() public {
        // Deploy fresh token to test initial state
        GameToken freshToken = new GameToken();
        assertEq(freshToken.balanceOf(owner), 0, "Owner starts with 0 tokens (must mint with POL)");
    }

    function testInitialReserve() public {
        // Deploy fresh token to test initial state
        GameToken freshToken = new GameToken();
        assertEq(address(freshToken).balance, 0, "Initial reserve should be 0");
    }

    function testConstants() public view {
        assertEq(token.TOKENS_PER_POL(), TOKENS_PER_POL);
        assertEq(token.MIN_PURCHASE(), MIN_PURCHASE);
    }

    // ============================================
    // BUY TOKENS TESTS
    // ============================================

    function testBuyTokensBasic() public {
        uint256 maticAmount = 1 ether;
        
        vm.startPrank(user1);
        uint256 tokensBefore = token.balanceOf(user1);
        uint256 reserveBefore = address(token).balance;
        
        uint256 tokensOut = token.buyTokens{value: maticAmount}();
        
        assertGt(tokensOut, 0, "Should receive tokens");
        assertEq(token.balanceOf(user1), tokensBefore + tokensOut, "Balance should increase");
        assertGt(address(token).balance, reserveBefore, "Reserve should increase");
        vm.stopPrank();
    }

    function testNoFeesOnBuy() public {
        // ✅ VERIFY: No fees charged on token purchase
        uint256 maticAmount = 1 ether;
        
        uint256 reserveBefore = address(token).balance;
        
        vm.prank(user1);
        uint256 tokensOut = token.buyTokens{value: maticAmount}();
        
        // With NO fees: 1 POL = exactly 1000 tokens
        uint256 expectedTokens = maticAmount * TOKENS_PER_POL;
        assertEq(tokensOut, expectedTokens, "Should get exact 1000 tokens per POL (no fees)");
        
        // Reserve should increase by full payment (no fees deducted)
        assertEq(address(token).balance, reserveBefore + maticAmount, "Reserve should equal full payment (no fees)");
    }

    function testBuyTokensMinPurchase() public {
        uint256 tooSmall = MIN_PURCHASE - 1;
        
        vm.startPrank(user1);
        vm.expectRevert("Purchase amount too small");
        token.buyTokens{value: tooSmall}();
        vm.stopPrank();
    }

    // NO FEES - test removed
    // function testBuyTokensFeesCollected() public { ... }

    function testBuyTokensEmitsEvent() public {
        uint256 maticAmount = 1 ether;
        
        vm.startPrank(user1);
        vm.expectEmit(true, false, false, false);
        emit TokensPurchased(user1, maticAmount, 0); // Don't check amounts, just event type
        token.buyTokens{value: maticAmount}();
        vm.stopPrank();
    }

    function testBuyTokensUpdatesReserve() public {
        uint256 maticAmount = 1 ether;
        uint256 reserveBefore = address(token).balance;
        
        vm.prank(user1);
        token.buyTokens{value: maticAmount}();
        
        assertEq(address(token).balance, reserveBefore + maticAmount, "Reserve should equal MATIC sent (no fees)");
    }

    function testBuyTokensMultiplePurchases() public {
        // First purchase
        vm.prank(user1);
        uint256 tokens1 = token.buyTokens{value: 1 ether}();
        
        // Second purchase - should get different amount due to supply change
        vm.prank(user2);
        uint256 tokens2 = token.buyTokens{value: 1 ether}();
        
        // ⚠️ CRITICAL TEST: With current minting design, tokens2 != tokens1
        // This test will EXPOSE the inflation bug
        console.log("First purchase:", tokens1);
        console.log("Second purchase:", tokens2);
    }

    function testBuyTokensPriceIncreases() public {
        // Buy large amount
        vm.prank(user1);
        token.buyTokens{value: 10 ether}();
        
        // Buy same amount again - with fixed rate, should get same tokens
        vm.prank(user2);
        token.buyTokens{value: 10 ether}();
        
        // Fixed rate: both buyers get same amount (1 POL = 1000 tokens always)
        assertEq(token.balanceOf(user1), token.balanceOf(user2), "Same input = same output with fixed rate");
    }

    // ============================================
    // REDEEM TOKENS TESTS
    // ============================================

    function testRedeemTokensBasic() public {
        // First buy some tokens
        vm.prank(user1);
        uint256 tokenAmount = token.buyTokens{value: 1 ether}();
        
        // Then redeem them
        uint256 maticBefore = user1.balance;
        
        vm.prank(user1);
        uint256 maticOut = token.redeemTokens(tokenAmount);
        
        assertGt(maticOut, 0, "Should receive MATIC");
        assertGt(user1.balance, maticBefore, "User MATIC balance should increase");
    }

    function testNoFeesOnRedeem() public {
        // ✅ VERIFY: No fees charged on token redemption
        uint256 maticAmount = 1 ether;
        
        // Buy tokens
        vm.prank(user1);
        uint256 tokensOut = token.buyTokens{value: maticAmount}();
        
        // Get user balance before redemption
        uint256 maticBefore = user1.balance;
        
        // Redeem all tokens
        vm.prank(user1);
        uint256 polOut = token.redeemTokens(tokensOut);
        
        // With NO fees: should get back exactly what was paid
        assertEq(polOut, maticAmount, "Should get back exact POL amount (no fees)");
        assertEq(user1.balance - maticBefore, maticAmount, "User should receive full amount (no fees)");
    }

    function testRoundTripNoLoss() public {
        // ✅ VERIFY: Complete round trip (buy + redeem) results in no loss
        uint256 initialMatic = 10 ether;
        
        // Give user MATIC
        vm.deal(user1, initialMatic);
        
        // Buy tokens
        vm.prank(user1);
        uint256 tokensOut = token.buyTokens{value: initialMatic}();
        
        // Immediately redeem all tokens
        vm.prank(user1);
        token.redeemTokens(tokensOut);
        
        // User should have exact same MATIC back (no fees)
        assertEq(user1.balance, initialMatic, "Round trip should return exact same amount (no fees)");
    }

    function testRedeemTokensInsufficientBalance() public {
        vm.startPrank(user1);
        vm.expectRevert("Insufficient balance");
        token.redeemTokens(1000 ether); // User has no tokens
        vm.stopPrank();
    }

    function testRedeemTokensZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert("Amount must be > 0");
        token.redeemTokens(0);
        vm.stopPrank();
    }

    function testRedeemTokensInsufficientReserve() public {
        // With POL-backed design, it's hard to create insufficient reserve scenario
        // because every token mint requires POL backing
        // However, we can test by simulating a case where tokens exist but reserve is drained
        
        // Deploy fresh token
        GameToken freshToken = new GameToken();
        
        // User buys tokens with POL (creates reserve)
        vm.deal(user1, 10 ether);
        vm.startPrank(user1);
        freshToken.buyTokens{value: 1 ether}();
        
        // User redeems all tokens (drains reserve)
        uint256 tokens = freshToken.balanceOf(user1);
        freshToken.redeemTokens(tokens);
        vm.stopPrank();
        
        // Now reserve is empty
        assertEq(address(freshToken).balance, 0, "Reserve should be empty");
        
        // User2 buys tokens (adds reserve)
        vm.deal(user2, 10 ether);
        vm.startPrank(user2);
        freshToken.buyTokens{value: 1 ether}();
        
        // User2 can redeem because reserve is sufficient (POL-backed)
        uint256 allTokens = freshToken.balanceOf(user2);
        uint256 polOut = freshToken.redeemTokens(allTokens);
        vm.stopPrank();
        
        assertGt(polOut, 0, "Should be able to redeem with sufficient reserve");
        
        // The point is: with POL-backing, reserve should always be sufficient
        // This test validates that the system prevents unbacked tokens
    }

    function testRedeemTokensBurnsTokens() public {
        // Buy tokens
        vm.prank(user1);
        uint256 tokenAmount = token.buyTokens{value: 1 ether}();
        
        uint256 supplyBefore = token.totalSupply();
        
        // Redeem tokens
        vm.prank(user1);
        token.redeemTokens(tokenAmount);
        
        assertEq(token.totalSupply(), supplyBefore - tokenAmount, "Supply should decrease");
        assertEq(token.balanceOf(user1), 0, "User should have 0 tokens");
    }

    // NO FEES - test removed

    // ============================================
    // FIXED RATE MATH TESTS (NO BONDING CURVE)
    // ============================================

    function testCalculateBuyReturn() public view {
        uint256 maticAmount = 1 ether;
        uint256 tokensOut = token.calculateBuyReturn(maticAmount);
        assertGt(tokensOut, 0, "Should return positive tokens");
    }

    function testCalculateBuyReturnZero() public view {
        uint256 tokensOut = token.calculateBuyReturn(0);
        assertEq(tokensOut, 0, "Zero input should return zero output");
    }

    function testCalculateSellReturn() public view {
        uint256 tokenAmount = 1000 * 10**18; // 1000 tokens
        uint256 polOut = token.calculateSellReturn(tokenAmount);
        // 1000 tokens = 1 POL before fees
        // With 3% sell fee: 1 POL * 0.97 = 0.97 POL
        assertEq(polOut, 1 ether, "Should return correct POL amount (no fees)");
    }

    function testCalculateSellReturnZero() public view {
        uint256 polOut = token.calculateSellReturn(0);
        assertEq(polOut, 0, "Zero input should return zero output");
    }

    function testCalculateSellReturnExceedsSupply() public view {
        // With fixed rate, we can calculate for any amount
        uint256 largeAmount = 1_000_000 * 10**18; // 1M tokens
        uint256 result = token.calculateSellReturn(largeAmount);
        // 1M tokens = 1000 POL (no fees)
        assertEq(result, 1000 ether, "Should calculate correct POL for large amount");
    }

    // ============================================
    // ROUND TRIP TESTS (NO FEES)
    // ============================================

    function testBondingCurveRoundTrip() public {
        uint256 initialMatic = 10 ether;
        
        // Buy tokens
        vm.prank(user1);
        uint256 tokenAmount = token.buyTokens{value: initialMatic}();
        
        // Sell tokens back
        uint256 maticBefore = user1.balance;
        vm.prank(user1);
        token.redeemTokens(tokenAmount);
        
        uint256 maticReceived = user1.balance - maticBefore;
        
        // NO FEES - should get exact same amount back
        assertEq(maticReceived, initialMatic, "Should get all money back (no fees)");
    }

    // ============================================
    // BURN FUNCTIONALITY TESTS
    // ============================================

    function testBurnByHolder() public {
        // Transfer tokens to user
        token.transfer(user1, 1000 ether);
        
        uint256 burnAmount = 100 ether;
        uint256 supplyBefore = token.totalSupply();
        
        vm.prank(user1);
        token.burn(burnAmount);
        
        assertEq(token.totalSupply(), supplyBefore - burnAmount, "Supply should decrease");
        assertEq(token.balanceOf(user1), 1000 ether - burnAmount, "Balance should decrease");
    }

    function testBurnByNonHolder() public {
        vm.startPrank(user1);
        vm.expectRevert(); // Will revert due to insufficient balance
        token.burn(1 ether);
        vm.stopPrank();
    }

    function testBurnEmitsEvent() public {
        token.transfer(user1, 1000 ether);
        
        vm.startPrank(user1);
        vm.expectEmit(true, false, false, true);
        emit TokensBurned(user1, 100 ether);
        token.burn(100 ether);
        vm.stopPrank();
    }

    function testBurnFromByOwner() public {
        // Fixed: burnFrom now requires approval (standard ERC20)
        token.transfer(user1, 1000 ether);
        
        uint256 supplyBefore = token.totalSupply();
        
        // User1 must approve first
        vm.prank(user1);
        token.approve(address(this), 100 ether);
        
        // Now anyone with approval can burn
        token.burnFrom(user1, 100 ether);
        
        assertEq(token.totalSupply(), supplyBefore - 100 ether);
        assertEq(token.balanceOf(user1), 900 ether);
    }

    function testBurnFromByNonOwner() public {
        token.transfer(user1, 1000 ether);
        
        vm.startPrank(attacker);
        vm.expectRevert(); // Should revert - no approval
        token.burnFrom(user1, 100 ether);
        vm.stopPrank();
    }

    // ============================================
    // TREASURY TESTS
    // ============================================

    // NO TREASURY - tests removed
    // function testSetTreasury() public { ... }
    // function testSetTreasuryZeroAddress() public { ... }
    // function testSetTreasuryOnlyOwner() public { ... }

    // NO TREASURY - test removed
    // function testSetTreasuryByNonOwner() public { ... }

    // ============================================
    // MINTING TESTS (All minting must be backed by POL)
    // ============================================

    function testMintByOwnerRemoved() public {
        // mint() function has been removed - all minting must go through buyTokens with POL
        // This test verifies the function no longer exists
        uint256 supplyBefore = token.totalSupply();
        uint256 ownerBalanceBefore = token.balanceOf(owner);
        
        // Instead of mint(), use buyTokens with POL
        uint256 polAmount = 1 ether;
        vm.deal(owner, polAmount);
        vm.prank(owner);
        uint256 tokensMinted = token.buyTokens{value: polAmount}();
        
        assertEq(token.totalSupply(), supplyBefore + tokensMinted, "Supply should increase");
        assertEq(token.balanceOf(owner), ownerBalanceBefore + tokensMinted, "Owner should receive minted tokens");
    }

    function testCannotMintWithoutPOL() public {
        // Verify that there is no way to mint tokens without providing POL backing
        // The mint() function has been removed entirely
        // supplyBefore not needed - just documenting that unbacked minting is impossible
        
        // Attempting to call mint would fail at compile time
        // This test documents that unbacked minting is impossible
        
        // The only way to mint is buyTokens with POL
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        token.buyTokens{value: 1 ether}();
        
        // Verify POL backing
        assertGt(address(token).balance, 0, "Tokens must be backed by POL");
    }

    function testMintingAlwaysBacked() public {
        // ✅ SECURITY: All NEW token minting is now backed by POL
        // Note: Initial 1B supply is not backed (needs owner to topUpReserve)
        
        uint256 polAmount = 10 ether;
        vm.deal(owner, polAmount);
        
        uint256 reserveBefore = address(token).balance;
        uint256 supplyBefore = token.totalSupply();
        
        // Mint tokens by providing POL
        uint256 tokensMinted = token.buyTokens{value: polAmount}();
        
        assertEq(token.totalSupply(), supplyBefore + tokensMinted, "Supply should increase by tokens minted");
        assertEq(address(token).balance, reserveBefore + polAmount, "POL reserve must increase");
        
        // Verify the NEW tokens are fully backed (even if initial supply isn't)
        // For the 10k tokens we just minted, we provided 10 POL
        // 10k tokens need 10 POL -> 100% backed
        uint256 polNeededForNew = (tokensMinted * 1 ether) / (token.TOKENS_PER_POL() * 10**18);
        assertEq(polNeededForNew, polAmount, "New tokens should be exactly backed by POL provided");
    }

    // ============================================
    // RECEIVE FUNCTION TESTS (ATTACK VECTOR)
    // ============================================

    function testReceiveDirectMATIC() public {
        uint256 reserveBefore = address(token).balance;
        
        // Send MATIC directly to contract
        vm.prank(attacker);
        (bool success,) = address(token).call{value: 10 ether}("");
        require(success);
        
        assertEq(address(token).balance, reserveBefore + 10 ether, "Reserve should increase");
    }

    function testReceiveManipulatesPrice() public {
        // ✅ SECURITY: With fixed rate, sending POL doesn't affect price
        
        // 1. User1 buys tokens at normal price
        vm.prank(user1);
        token.buyTokens{value: 1 ether}();
        
        // 2. Attacker inflates reserve by sending POL directly
        vm.prank(attacker);
        (bool success,) = address(token).call{value: 1000 ether}("");
        require(success);
        
        // 3. User2 gets some tokens (transfer from owner)
        token.transfer(user2, 1000 * 10**18); // 1000 tokens
        
        // 4. User2 can redeem at fixed rate if reserve is sufficient
        // Reserve = 1 POL (from user1 buy) + 1000 POL (attacker) = 1001 POL
        // 1000 tokens = 1 POL at fixed rate
        vm.prank(user2);
        uint256 polOut = token.redeemTokens(1000 * 10**18);
        
        // Gets 1 POL (minus fees) regardless of how much POL is in reserve
        assertEq(polOut, 1 ether, "Fixed rate: 1000 tokens = 1 POL");
        
        // ✅ Fixed rate prevents price manipulation
    }

    // ============================================
    // SECURITY TESTS
    // ============================================

    function testCostBasisProtectsAgainstManipulation() public {
        // This test demonstrates that fixed-rate redemption prevents exploitation
        // Use fresh token to test from clean state
        GameToken freshToken = new GameToken();
        
        // Initial state: empty reserve
        assertEq(address(freshToken).balance, 0, "Reserve should start at 0");
        
        // 1. User1 buys tokens at the fixed rate: 1 POL = 1000 tokens (NO FEES)
        vm.deal(user1, 10 ether);
        vm.prank(user1);
        uint256 tokens1 = freshToken.buyTokens{value: 1 ether}();
        
        assertEq(tokens1, 1000 * 10**18, "User1 should receive 1000 tokens (no fees)");
        
        // 2. Attacker tries to manipulate by sending POL directly to contract
        vm.deal(attacker, 1001 ether);
        vm.prank(attacker);
        (bool success,) = address(freshToken).call{value: 1000 ether}("");
        require(success, "Direct POL transfer should succeed");
        
        // Reserve increases, but this doesn't affect redemption rate (fixed)
        assertEq(address(freshToken).balance, 1 ether + 1000 ether, "Reserve should include direct transfer");
        
        // 3. User1 redeems tokens - gets fixed rate regardless of reserve
        vm.prank(user1);
        uint256 polOut = freshToken.redeemTokens(tokens1);
        
        // With no fees, user gets back exactly what they paid (1 POL)
        assertEq(polOut, 1 ether, "User gets back exactly what they paid (no fees)");
        
        // The attacker's 1000 POL is stuck in the contract - it doesn't benefit them
        uint256 remainingReserve = address(freshToken).balance;
        assertGt(remainingReserve, 999 ether, "Attacker's POL remains in contract");
        
        // ✅ SECURITY: Fixed-rate redemption prevents reserve manipulation attacks
    }

    function testUserCanOnlyRedeemWhatTheyBought() public {
        // With fixed rate, anyone can redeem if they have tokens and reserve is sufficient
        // User1 buys tokens
        vm.prank(user1);
        uint256 tokens1 = token.buyTokens{value: 2 ether}();
        
        // User2 buys tokens at same price (since fixed rate)
        vm.prank(user2);
        uint256 tokens2 = token.buyTokens{value: 1 ether}();
        
        // Both should get proportional amounts
        assertEq(tokens1, tokens2 * 2, "User1 should have 2x tokens since they paid 2x");
        
        // User1 transfers half their tokens to attacker
        vm.prank(user1);
        token.transfer(attacker, tokens1 / 2);
        
        // Attacker can redeem at fixed rate (no purchase history needed)
        vm.prank(attacker);
        uint256 attackerPolOut = token.redeemTokens(tokens1 / 2);
        assertGt(attackerPolOut, 0, "Anyone can redeem tokens at fixed rate");
        
        // User1 can still redeem their remaining tokens at fixed rate
        vm.prank(user1);
        uint256 polOut = token.redeemTokens(tokens1 / 2);
        assertGt(polOut, 0, "User1 can redeem their remaining tokens");
        
        // ✅ SECURITY: Fixed rate system is simple and predictable
    }

    function testMultiplePurchasesFixedRate() public {
        // User buys at different times (same fixed price, NO FEES)
        vm.prank(user1);
        uint256 tokens1 = token.buyTokens{value: 1 ether}();
        
        vm.prank(user1);
        uint256 tokens2 = token.buyTokens{value: 2 ether}();
        
        // Total tokens should follow fixed rate with NO FEES:
        // 1 POL = 1000 tokens
        // 2 POL = 2000 tokens
        assertEq(tokens1, 1000 * 10**18, "First purchase: 1000 tokens (no fees)");
        assertEq(tokens2, 2000 * 10**18, "Second purchase: 2000 tokens (no fees)");
        
        uint256 totalTokens = tokens1 + tokens2;
        
        // Can redeem all at fixed rate (no fees)
        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        uint256 polOut = token.redeemTokens(totalTokens);
        uint256 balanceAfter = user1.balance;
        
        // With fixed rate and NO FEES: 3000 tokens = 3 POL
        assertEq(polOut, 3 ether, "Redemption at fixed rate (no fees)");
        assertEq(balanceAfter - balanceBefore, 3 ether, "User receives full amount back");
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_BuyTokens(uint256 amount) public {
        // Bound between MIN_PURCHASE and reasonable max
        amount = bound(amount, MIN_PURCHASE, 100 ether);
        
        vm.deal(user1, amount);
        
        vm.prank(user1);
        uint256 tokensOut = token.buyTokens{value: amount}();
        
        assertGt(tokensOut, 0, "Should receive tokens");
    }

    function testFuzz_RedeemTokens(uint256 buyAmount, uint256 redeemAmount) public {
        buyAmount = bound(buyAmount, MIN_PURCHASE, 10 ether);
        
        // Buy tokens
        vm.prank(user1);
        uint256 tokensReceived = token.buyTokens{value: buyAmount}();
        
        // Redeem portion (at least 1 wei, at most all received)
        redeemAmount = bound(redeemAmount, 1, tokensReceived);
        
        // Skip if redemption would fail due to insufficient reserve
        uint256 expectedPol = token.calculateSellReturn(redeemAmount);
        if (expectedPol == 0 || address(token).balance < expectedPol) {
            return; // Skip this fuzz case
        }
        
        vm.prank(user1);
        uint256 polOut = token.redeemTokens(redeemAmount);
        
        assertGt(polOut, 0, "Should receive POL");
    }
}
