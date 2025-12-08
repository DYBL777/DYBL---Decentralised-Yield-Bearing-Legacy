// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * DYBL - Decentralised Yield Bearing Legacy
 *
 * 100 % of every sale flows into one transparent Aave/Compound vault forever
 * The DYBL primitive works for any recurring payment: lottery, insurance, pensions, subs, SaaS, utilities...
 * Lettery is the flagship first product.
 *
 * Immutable rules (locked forever at deploy):
 * • Treasury revenue → 0 % forever the moment the pre-determined state is reached
 * • 100 % of prize-pot yield belongs to savers forever
 * • Post-cap excess → permanent saver APY + charity + treasury passive slice (future)
 * • Unique Yield-Bearing Mechanism – works even if Aave/Compound yield drops to 0 %
 * • Unique saver-focussed Pavlovian toggle
 * • Legacy Mode activates after set time of perfect saving
 * • Self-funding Chainlink reserve – for payments on future projects
 * • No token. No governance. No pre-mine. No VC. No rug.
 * • The End.. of the beginning
 */

import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@aave/core-v3/contracts/interfaces/IPool.sol";

/// @title Lettery – Perpetual Treasury + 42-char meme draw + yearly loyalty gift
/// @author DYBL Foundation
/// @notice All numbers in this contract are approximate examples for draft purposes only.
 /// Final values will be set immutably at deployment.
/// @dev BLACK-SWAN & RESILIENCE SCENARIOS (planned, not active code)
/// These are pre-considered, audited-ready migration paths that can be activated
/// by the immutable owner + timelock in case of extreme events.
/// Chainlink Engineering is explicitly invited to co-design the final implementation.
/// 1. Aave Protocol Exploit or Insolvency
///    → EmergencyPause → withdrawAllFromAave() → supplyToBackupLendingProtocol()
///       (e.g. Compound, Morpho Blue, Spark, or new Aave fork)
///    → All user balances + accrued yield preserved 1:1 via internal accounting
/// 2. Chainlink VRF Coordinator Prolonged Outage (>72 h)
///    → Switch to backup Chainlink VRF Coordinator (pre-registered subscription)
///    → If both coordinators down → fallback to Chainlink Automation-registered manual fulfilment
///       using verifiable off-chain randomness signed by 5/7 Chainlink nodes
/// 3. Base/Ethereum L2 51% Attack or Deep Reorg
///    → Pause new deposits/draws
///    → Users’ funds remain safe in Aave (on Ethereum mainnet) – no L2 state risk
///    → Post-resolution: optional CCIP bridge to a new destination chain
///       (Arbitrum, Optimism, zkSync Era, or future Chainlink-recommended rollup)
/// 4. Chainlink Network Full Oracle Failure (hypothetical)
///    → Activate pre-deployed “Chainlink Keepers + Blockhash” contingency draw
///       (still trust-minimized, still verifiable, used only as last resort)
/// 5. Regulatory or Forced Migration Event
///    → Timelocked migrateToNewChain(uint64 newChainSelector, address newPool, address newCoordinator)
///       using Chainlink CCIP – burns/mints USDC cross-chain, preserves every saver balances
/// 6. Owner Key Compromise (absolute worst case)
///    → 48-hour TimelockController + 5-of-9 multisig of reputable Chainlink ecosystem partners
///       (Chainlink Labs, Coinbase, Aave Companies, etc.) can execute recovery
/// @dev // Supports any currency via off-chain ramps to USDC for global access.
/// @dev // Optional Chainlink DID/GLEIF for verified users – enhances legacy/trust without centralization.
/// @dev // DYBL: Business/game primitive – saver rewards earned via consistency, not charity.
contract Lettery is VRFConsumerBaseV2, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═════════════════════════════════════════════════════════════════════════════
    // IMMUTABLE PARAMETERS
    // ═════════════════════════════════════════════════════════════════════════════
    uint256 public immutable JACKPOT_CAP;
    uint256 public immutable ZERO_REVENUE_TIMESTAMP;
    uint256 public immutable ETERNAL_SEED_BPS;                 // The Eternal Seed – DeFi's first autonomous yield engine
    uint256 public immutable LEGACY_ACTIVATION_YEARS;          // e.g. 2
    uint256 public immutable WITHDRAW_LOCK_YEARS;              // e.g. 3
    uint256 public immutable DEPLOY_TIMESTAMP;

    address public immutable USDC;
    address public immutable aUSDC;
    address public immutable AAVE_POOL;
    address public immutable CHARITY_WALLET;
    address public immutable SAVER_YIELD_POOL;

    VRFCoordinatorV2Interface public immutable COORDINATOR;
    uint64  public immutable SUBSCRIPTION_ID;
    bytes32 public immutable KEY_HASH;

    // ═════════════════════════════════════════════════════════════════════════════
    // THE OFFICIAL DYBL 42-CHARACTER MEME ALPHABET
    // ═════════════════════════════════════════════════════════════════════════════
    /// A–Z (26) + 0–9 (10) + ! @ # $ % & (6) = exactly 42 symbols forever
    /// This set is immutable, hard-coded, and defines the entire game.
    /// Every weekly draw = 6 unique symbols from these 42 → 42P6 ≈ 5.2 billion possible combos
    bytes1[42] public constant MEME_ALPHABET = [
        bytes1(0x41),0x42,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x4A, // A–J
        0x4B,0x4C,0x4D,0x4E,0x4F,0x50,0x51,0x52,0x53,0x54, // K–T
        0x55,0x56,0x57,0x58,0x59,0x5A,                   // U–Z
        0x30,0x31,0x32,0x33,0x34,0x35,0x36,0x37,0x38,0x39, // 0–9
        0x21,0x40,0x23,0x24,0x25,0x26                    // ! @ # $ % &
    ];

    // ═════════════════════════════════════════════════════════════════════════════
    // STATE VARIABLES
    // ═════════════════════════════════════════════════════════════════════════════
    uint256 public prizePot;
    uint256 public treasuryOperatingReserve;   // True ops buffer (min approximately 15% in Y1)
    uint256 public treasuryGiftReserve;        // Ring-fenced for cash-back + free tickets
    uint256 public totalSaverBalance;

    uint256 public treasuryTakeBps = 3500;     // approximately 35% initial, onlyOwner can decrease
    uint256 public currentWeek;
    uint256 public lastDrawTimestamp;

    mapping(address => uint256) public saverBalance;
    mapping(address => uint256) public ticketsBought;
    mapping(address => uint256) public streakWeeks;
    mapping(address => uint256) public lastBuyTimestamp;
    mapping(address => uint256) public yieldMultiplierBps;     // 10000 = 100% yield, gamblers get approximately 5000
    mapping(address => address) public heir;
    mapping(address => uint256) public playEntriesThisWeek;
    mapping(address => string) public thisWeekGuess; // User's 6-char guess

    address[] public playersThisWeek;
    uint256 public totalPlayEntriesThisWeek;

    // Special weeks (1/6 wins free ticket)
    bool public isCommunityWeek;
    uint256 public lastCommunityWeekTimestamp;

    // Weekly results for tiered prizes
    struct WeeklyResult {
        string combo;
        address[] jackpotWinners; // 6/6
        address[] match5;
        address[] match4;
        address[] match3;
        address[] match2;
        address[] match1; // Community week only
    }
    mapping(uint256 => WeeklyResult) public weeklyResults;

    // ═════════════════════════════════════════════════════════════════════════════
    // CONSTANTS (approximate examples)
    // ═════════════════════════════════════════════════════════════════════════════
    uint256 public constant TICKET_PRICE = 3e6; // $3 USDC
    uint256 public constant PAYOUT_PERCENT_BPS = 5500; // 55 % of prizePot paid out
    uint256[5] public constant TIERS_PERCENT_OF_55 = [
        4000,  // 6/6 → 40 % of the 55 %
        2500,  // 5/6 → 25 %
        2000,  // 4/6 → 20 %
        1000,  // 3/6 → 10 %
         500   // 2/6 →  5 %
    ];

    // Saver cash-back (45 % total over 3 years e.g.)
    uint256 public constant SAVER_CB_BPS_Y1 = 1000;   // approximately 10%
    uint256 public constant SAVER_CB_BPS_Y2 = 1500;   // approximately 15%
    uint256 public constant SAVER_CB_BPS_Y3 = 2000;   // approximately 20%

    // Gambler rewards (approximately half or less, paid in free tickets)
    uint256 public constant GAMBLER_CB_BPS_Y1 = 500;
    uint256 public constant GAMBLER_CB_BPS_Y2 = 750;
    uint256 public constant GAMBLER_CB_BPS_Y3 = 1000;

    // ═════════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═════════════════════════════════════════════════════════════════════════════
    event TicketBought(address indexed user, bool playMode, uint256 week);
    event WinningComboDrawn(uint256 indexed week, string combo);
    event WinnerSelected(address indexed winner, uint256 amount, uint256 matchLevel);
    event CashbackClaimed(address indexed user, uint256 year, uint256 amount, bool isCash);
    event StreakBroken(address indexed user, uint256 forfeitedYield);
    event HeirSet(address indexed user, address heir);
    event HeirClaimed(address indexed heir, address indexed original, uint256 amount);
    event EternalSeedInjected(uint256 amount);
    event CommunityWeekDeclared(uint256 week);

    // ═════════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════════
    constructor(
        address _vrfCoordinator,
        uint64 _subId,
        bytes32 _keyHash,
        address _usdc,
        address _aavePool,
        uint256 _jackpotCap,
        uint256 _zeroYears,
        uint256 _eternalSeedBps,
        address _charity,
        address _saverYieldPool,
        uint256 _legacyYears,
        uint256 _withdrawLockYears
    ) VRFConsumerBaseV2(_vrfCoordinator) {
        COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);
        SUBSCRIPTION_ID = _subId;
        KEY_HASH = _keyHash;

        USDC = _usdc;
        AAVE_POOL = _aavePool;
        (,,,,address aToken,,,,,) = IPool(_aavePool).getReserveData(_usdc);
        aUSDC = aToken;

        JACKPOT_CAP = _jackpotCap;
        ZERO_REVENUE_TIMESTAMP = block.timestamp + _zeroYears * 365 days;
        ETERNAL_SEED_BPS = _eternalSeedBps;

        CHARITY_WALLET = _charity;
        SAVER_YIELD_POOL = _saverYieldPool;

        DEPLOY_TIMESTAMP = block.timestamp;
        lastDrawTimestamp = block.timestamp;

        LEGACY_ACTIVATION_YEARS = _legacyYears;
        WITHDRAW_LOCK_YEARS = _withdrawLockYears;
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // CORE GAMEPLAY
    // ═════════════════════════════════════════════════════════════════════════════
    function buyTicket(bool playThisWeek, string calldata userGuess) external nonReentrant {
        require(bytes(userGuess).length == 6, "Guess must be 6 chars");
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), TICKET_PRICE);
        IERC20(USDC).safeApprove(AAVE_POOL, TICKET_PRICE);
        IPool(AAVE_POOL).supply(USDC, TICKET_PRICE, address(this), 0);

        // Treasury split (approximately 35% → 20% gift reserve + 15% ops)
        uint256 prizeAllocation = TICKET_PRICE * (10000 - treasuryTakeBps) / 10000;
        prizePot += prizeAllocation;

        uint256 treasurySlice = TICKET_PRICE - prizeAllocation;
        treasuryGiftReserve += treasurySlice * 5714 / 10000;           // approximately 20% of total
        treasuryOperatingReserve += treasurySlice - (treasurySlice * 5714 / 10000);

        // Streak & forfeit logic
        if (block.timestamp > lastBuyTimestamp[msg.sender] + 8 days) {
            uint256 forfeited = _forfeitYield(msg.sender);
            if (forfeited > 0) emit StreakBroken(msg.sender, forfeited);
            streakWeeks[msg.sender] = 1;
        } else {
            streakWeeks[msg.sender]++;
        }
        lastBuyTimestamp[msg.sender] = block.timestamp;
        ticketsBought[msg.sender]++;

        if (playThisWeek) {
            if (playEntriesThisWeek[msg.sender] == 0) playersThisWeek.push(msg.sender);
            playEntriesThisWeek[msg.sender]++;
            totalPlayEntriesThisWeek++;
            yieldMultiplierBps[msg.sender] = 5000;  // Gamblers get approximately 50% yield
        } else {
            saverBalance[msg.sender] += TICKET_PRICE;
            totalSaverBalance += TICKET_PRICE;
            yieldMultiplierBps[msg.sender] = 10000; // Savers get 100%
        }

        thisWeekGuess[msg.sender] = userGuess;

        emit TicketBought(msg.sender, playThisWeek, currentWeek);

        if (block.timestamp >= lastDrawTimestamp + 7 days) _requestRandomness();
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // CHAINLINK VRF CALLBACK – THE WEEKLY HEARTBEAT
    // ═════════════════════════════════════════════════════════════════════════════
    function fulfillRandomWords(uint256, uint256[] memory randomWords) internal override {
        if (block.timestamp >= ZERO_REVENUE_TIMESTAMP) treasuryTakeBps = 0;

        // The Eternal Seed – autonomous yield engine
        uint256 seed = (prizePot + treasuryOperatingReserve + treasuryGiftReserve) * ETERNAL_SEED_BPS / 10000;
        if (seed > 0) {
            if (seed <= treasuryOperatingReserve) {
                treasuryOperatingReserve -= seed;
            } else {
                seed = treasuryOperatingReserve;
                treasuryOperatingReserve = 0;
            }
            prizePot += seed;
            emit EternalSeedInjected(seed);
        }

        // 42-char meme draw
        string memory combo = _generateMemeCombo(randomWords[0]);
        emit WinningComboDrawn(++currentWeek, combo);
        weeklyResults[currentWeek].combo = combo;

        // Distribute tiered prizes
        _distributeWeeklyPrizes();

        // Reset week
        for (uint256 i = 0; i < playersThisWeek.length; i++) {
            playEntriesThisWeek[playersThisWeek[i]] = 0;
            thisWeekGuess[playersThisWeek[i]] = "";
        }
        delete playersThisWeek;
        totalPlayEntriesThisWeek = 0;
        lastDrawTimestamp = block.timestamp;
    }

    function _distributeWeeklyPrizes() internal {
        uint256 payoutPool = prizePot * PAYOUT_PERCENT_BPS / 10000; // 55 %
        prizePot -= payoutPool;

        uint256[5] memory tierAmounts;
        for (uint256 i = 0; i < 5; i++) {
            tierAmounts[i] = payoutPool * TIERS_PERCENT_OF_55[i] / 10000;
        }

        // Count matches
        for (uint256 i = 0; i < playersThisWeek.length; i++) {
            address user = playersThisWeek[i];
            uint256 matches = _countMatches(weeklyResults[currentWeek].combo, thisWeekGuess[user]);

            if (matches == 6) weeklyResults[currentWeek].jackpotWinners.push(user);
            else if (matches == 5) weeklyResults[currentWeek].match5.push(user);
            else if (matches == 4) weeklyResults[currentWeek].match4.push(user);
            else if (matches == 3) weeklyResults[currentWeek].match3.push(user);
            else if (matches == 2) weeklyResults[currentWeek].match2.push(user);
            else if (isCommunityWeek && matches == 1) weeklyResults[currentWeek].match1.push(user);
        }

        _payTier(weeklyResults[currentWeek].jackpotWinners, tierAmounts[0], 6);
        _payTier(weeklyResults[currentWeek].match5, tierAmounts[1], 5);
        _payTier(weeklyResults[currentWeek].match4, tierAmounts[2], 4);
        _payTier(weeklyResults[currentWeek].match3, tierAmounts[3], 3);
        _payTier(weeklyResults[currentWeek].match2, tierAmounts[4], 2);

        if (isCommunityWeek) {
            for (uint256 i = 0; i < weeklyResults[currentWeek].match1.length; i++) {
                address winner = weeklyResults[currentWeek].match1[i];
                // Free ticket for next week
                playEntriesThisWeek[winner] += 1;
                totalPlayEntriesThisWeek += 1;
                emit WinnerSelected(winner, TICKET_PRICE, 1);
            }
            isCommunityWeek = false;
        }
    }

    function _payTier(address[] memory winners, uint256 amount, uint256 matchLevel) internal {
        if (winners.length == 0) {
            prizePot += amount; // Roll over if no winners
            return;
        }
        uint256 perWinner = amount / winners.length;
        IPool(AAVE_POOL).withdraw(USDC, amount, address(this));
        for (uint256 i = 0; i < winners.length; i++) {
            IERC20(USDC).safeTransfer(winners[i], perWinner);
            emit WinnerSelected(winners[i], perWinner, matchLevel);
        }
    }

    function _countMatches(string memory combo, string memory guess) internal pure returns (uint256) {
        bytes memory c = bytes(combo);
        bytes memory g = bytes(guess);
        uint256 count = 0;
        for (uint256 i = 0; i < 6; i++) {
            for (uint256 j = 0; j < 6; j++) {
                if (c[i] == g[j]) count++;
            }
        }
        return count;
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // LOYALTY CASHBACK + FREE TICKETS
    // ═════════════════════════════════════════════════════════════════════════════
    function claimCashback() external nonReentrant {
        uint256 year = (block.timestamp - DEPLOY_TIMESTAMP) / 365 days + 1;
        require(year <= 4, "Claims ended");

        uint256 bps = year == 1 ? SAVER_CB_BPS_Y1 :
                      year == 2 ? SAVER_CB_BPS_Y2 :
                      year == 3 ? SAVER_CB_BPS_Y3 : 0;

        if (yieldMultiplierBps[msg.sender] != 10000) { // Not a perfect saver
            bps = year == 1 ? GAMBLER_CB_BPS_Y1 :
                year == 2 ? GAMBLER_CB_BPS_Y2 :
                year == 3 ? GAMBLER_CB_BPS_Y3 : 0;
        }

        require(bps > 0 && treasuryGiftReserve > 0, "Nothing to claim");
        uint256 claimable = ticketsBought[msg.sender] * TICKET_PRICE * bps / 10000;
        if (claimable == 0) return;

        treasuryGiftReserve -= claimable;

        if (yieldMultiplierBps[msg.sender] == 10000) {
            IERC20(USDC).safeTransfer(msg.sender, claimable);
        } else if (canGambleWithYield(msg.sender)) {
            uint256 freeTickets = claimable / TICKET_PRICE;
            playEntriesThisWeek[msg.sender] += freeTickets;
            totalPlayEntriesThisWeek += freeTickets;
        } // else forfeited

        emit CashbackClaimed(msg.sender, year, claimable, yieldMultiplierBps[msg.sender] == 10000);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // SAVER WITHDRAW (EOY only for first N years)
    // ═════════════════════════════════════════════════════════════════════════════
    function withdrawSavings() external nonReentrant {
        uint256 year = (block.timestamp - DEPLOY_TIMESTAMP) / 365 days + 1;
        if (year <= WITHDRAW_LOCK_YEARS) {
            require(_isEndOfYear(), "Withdraw only at EOY for early years");
        }

        uint256 principal = saverBalance[msg.sender];
        uint256 yield = getUserYield(msg.sender);
        uint256 total = principal + yield;

        require(total > 0, "Nothing to withdraw");
        saverBalance[msg.sender] = 0;
        totalSaverBalance -= principal;

        IPool(AAVE_POOL).withdraw(USDC, total, address(this));
        IERC20(USDC).safeTransfer(msg.sender, total);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // LEGACY MODE
    // ═════════════════════════════════════════════════════════════════════════════
    function setHeir(address _heir) external {
        require((block.timestamp - DEPLOY_TIMESTAMP) / 365 days + 1 >= LEGACY_ACTIVATION_YEARS, "Too early");
        heir[msg.sender] = _heir;
        emit HeirSet(msg.sender, _heir);
    }

    function claimInheritance(address original) external {
        require(heir[original] == msg.sender, "Not heir");
        require(block.timestamp > lastBuyTimestamp[original] + 10 * 365 days, "Still active");

        uint256 total = saverBalance[original] + getUserYield(original);
        require(total > 0, "Nothing left");

        saverBalance[original] = 0;
        totalSaverBalance -= saverBalance[original];

        IPool(AAVE_POOL).withdraw(USDC, total, address(this));
        IERC20(USDC).safeTransfer(msg.sender, total);

        emit HeirClaimed(msg.sender, original, total);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS (for frontend)
    // ═════════════════════════════════════════════════════════════════════════════
    function getUserYield(address user) public view returns (uint256) {
        if (totalSaverBalance == 0) return 0;
        uint256 totalYield = IERC20(aUSDC).balanceOf(address(this)) 
                           - prizePot 
                           - treasuryOperatingReserve 
                           - treasuryGiftReserve 
                           - totalSaverBalance;
        return saverBalance[user] * yieldMultiplierBps[user] / 10000 * totalYield / totalSaverBalance;
    }

    function canGambleWithYield(address user) public view returns (bool) {
        return getUserYield(user) >= 1e6; // approximately $1 threshold e.g.
    }

    function _isEndOfYear() internal view returns (bool) {
        uint256 dayOfYear = (block.timestamp % 365 days) / 1 days;
        return dayOfYear >= 350; // Last approximately 2 weeks of year
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═════════════════════════════════════════════════════════════════════════════
    function _generateMemeCombo(uint256 randomness) internal pure returns (string memory) {
        bytes1[42] memory chars = MEME_ALPHABET;
        string memory combo = "";
        uint256 rand = randomness;
        uint256 remaining = 42;
        for (uint i = 0; i < 6; i++) {
            uint256 idx = rand % remaining;
            combo = string(abi.encodePacked(combo, chars[idx]));
            chars[idx] = chars[remaining - 1];
            remaining--;
            rand = uint256(keccak256(abi.encode(rand)));
        }
        return combo;
    }

    function _forfeitYield(address user) internal returns (uint256) {
        uint256 yield = getUserYield(user);
        if (yield == 0) return 0;
        uint256 forfeit = yield * 5000 / 10000; // approximately 50% penalty
        treasuryOperatingReserve += forfeit;
        streakWeeks[user] = 0;
        return forfeit;
    }

    function _requestRandomness() internal {
        COORDINATOR.requestRandomWords(KEY_HASH, SUBSCRIPTION_ID, 3, 300000, 1);
    }

    // Owner-only (only downward)
    function decreaseTreasuryTake(uint256 newBps) external onlyOwner {
        require(newBps < treasuryTakeBps, "Can only decrease");
        treasuryTakeBps = newBps;
    }

    function declareCommunityWeek() external onlyOwner {
        require(block.timestamp > lastCommunityWeekTimestamp + 90 days, "Quarterly only");
        isCommunityWeek = true;
        lastCommunityWeekTimestamp = block.timestamp;
        emit CommunityWeekDeclared(currentWeek);
    }

    function triggerDraw() external {
        require(block.timestamp >= lastDrawTimestamp + 7 days, "Too early");
        _requestRandomness();
    }

    function fundChainlink(uint256 amount) external onlyOwner {
        require(amount <= treasuryOperatingReserve, "Insufficient");
        treasuryOperatingReserve -= amount;
        // Placeholder for LINK transfer to sub
    }
}    // ====================================================================
    // FUTURE-PROOF UPGRADE PATH (Chainlink-recommended)
    // ====================================================================
    // Core vault is immutable. Game rules can be upgraded via proxy + multisig later.
    // No backdoors today — onlyOwner functions are minimal and one-way.
}
