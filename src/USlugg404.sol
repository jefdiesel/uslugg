// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISeedSource}      from "./ISeedSource.sol";
import {IUSluggRenderer}  from "./IUSluggRenderer.sol";
import {IUSluggClaimed, IUSluggClaimedAdmin} from "./IUSluggClaimed.sol";

/// @notice Minimal sell/buy router surface used by callHook(). The real router
/// (USluggSwap) implements this; we only need the two entry points here.
interface IUSluggSwapRouter {
    function sell(uint256 usluggAmount, uint256 minEthOut, uint256 deadline) external returns (uint256 ethOut);
    function buy(uint256 usluggOut, uint256 maxEthIn, uint256 deadline) external payable returns (uint256 ethSpent);
}

/// @notice Hybrid ERC-20 + Slugg NFT, with ERC-721 visibility events so wallets
/// and explorers auto-detect the NFTs without an explicit wrap.
///
/// Holding 1.000 USLUG token = owning 1 Slugg NFT (joined at the hip). Selling
/// burns your NFT; the buyer gets a freshly-minted one with a new seed (so a
/// token unit cycling through 3 owners has been 3 different sluggs).
///
/// You can OPTIONALLY `wrap(id)` to lift a specific Slugg out into a
/// standalone USluggClaimed ERC-721 (separately tradeable on OpenSea, etc.).
/// wrap() charges a fee in ETH that goes to the treasury.
///
/// Decimals: 3. Smallest unit = 0.001 USLUG (1 raw). Mint threshold = 1.000 USLUG (1e3 raw).
/// People can hold fractional USLUG without minting an NFT — collectible above 1.0.
///
/// SEED-AWARE AUTO-MINT (the "404 magic"):
///   The receive-side auto-mint in `_move` is gated on
///   `seed.swapFiredThisTx()` — only USLUG that arrives via the locked-pool
///   swap (path A: USluggSwap.buy) or callHook's round-trip (path C) gets
///   matching sluggs minted. Direct ERC-20 transfers, faucet drips, airdrops,
///   and aggregator routes that don't touch the locked pool deliver USLUG
///   without sluggs — holders can call `callHook` later to materialize them
///   with a fresh on-chain seed.
contract USlugg404 {
    string  public constant name     = "uSlugg";
    string  public constant symbol   = "USLUG";
    uint8   public constant decimals = 3;

    uint256 public immutable maxSluggs;
    uint256 public immutable tokensPerSlugg;
    uint256 public immutable totalSupply;

    /// @notice A Slugg starts unrevealed: `seed = bytes32(0)` and `mintBlock`
    /// is the block at which it was minted. After REVEAL_DELAY blocks, anyone
    /// can call `reveal(id)` to lock in `seed` from `blockhash(mintBlock + REVEAL_DELAY)`.
    /// This makes the seed unpredictable to the builder of the mint block —
    /// they would have to also build block (mintBlock + REVEAL_DELAY) to control
    /// the resulting hash, which is vanishingly unlikely.
    struct Slugg {
        bytes32 seed;          // bytes32(0) until reveal()
        address originalMinter;
        uint64  mintBlock;     // L1 block number at which this slugg was minted
    }

    /// @dev Number of blocks after mint before reveal becomes possible.
    /// 2 means: builder of block N would need to also build block N+2 to
    /// control the seed. Probability for largest staker (~33%) doing both:
    /// ~10%. With each additional block, this drops geometrically. 2 is a
    /// pragmatic floor — UX cost is ~24s wait before art shows.
    uint64 public constant REVEAL_DELAY = 2;

    // ERC-20 state
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // NFT state
    mapping(uint256 => Slugg)     public sluggs;
    mapping(uint256 => address)   public ownerOf;
    mapping(address => uint256[]) internal _inventory;
    mapping(address => bool)      public skipSluggs;

    uint256 public nextSluggId;
    /// @dev `owner` is set in constructor and never changes (no transferOwnership).
    /// Marking immutable saves the SLOAD on every onlyOwner check.
    address public immutable owner;
    address payable public treasury;
    /// @dev Wrap fee in ETH (wei). Sent to treasury when a holder calls wrap().
    uint256 public wrapFeeWei;
    /// @dev Unwrap fee in ETH (wei). Discourages tight round-trip wrapping.
    uint256 public unwrapFeeWei;

    /// @dev Locked-pool swap router used by callHook to round-trip USLUG and
    /// roll a fresh seed. Set ONCE via setSwapRouter (one-shot, onlyOwner).
    /// address(0) until set; callHook reverts in that state.
    address public swapRouter;
    bool internal _routerSet;

    /// @dev Immutable: pinned at deploy. No setter exists. Closes the backdoor
    /// where a compromised owner could repoint randomness at a controlled
    /// source and grind any rare seed.
    ISeedSource public immutable seed;
    IUSluggRenderer public renderer;
    IUSluggClaimed  public claimedNft;

    // -------- events --------

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    // ERC-721 visibility (separate event because Solidity disallows event overload)
    event Transfer721(address indexed from, address indexed to, uint256 indexed id);

    event SluggMinted(uint256 indexed id, address indexed to, uint64 mintBlock);
    event SluggRevealed(uint256 indexed id, bytes32 seed);
    event SluggBurned(uint256 indexed id, address indexed from);
    event SeedSourceSet(address indexed seed);
    event SkipSet(address indexed account, bool skipped);
    event RendererSet(address indexed renderer);
    event ClaimedNftSet(address indexed claimedNft);
    event TreasuryProposed(address indexed previousTreasury, address indexed pendingTreasury);
    event TreasurySet(address indexed treasury);
    event WrapFeeSet(uint256 feeWei);
    event UnwrapFeeSet(uint256 feeWei);
    event WrapFeePaid(address indexed payer, address indexed treasury, uint256 amount);
    event SluggWrapped(address indexed holder, uint256 indexed sluggId, uint256 indexed claimedId, uint256 fee);
    event SluggUnwrapped(address indexed holder, uint256 indexed claimedId, uint256 indexed newSluggId);
    event SwapRouterSet(address indexed router);
    /// @notice callHook completed. `usluggIn` was pulled from the caller, `ethRoundTrip`
    /// is the ETH the sell leg produced (= the ETH ceiling spent on the buy leg before
    /// refund), `usluggBack` was returned to the caller, and `count` sluggs were minted
    /// with the post-second-swap seed.
    event CallHookCompleted(
        address indexed caller,
        uint256 usluggIn,
        uint256 ethRoundTrip,
        uint256 usluggBack,
        uint256 count
    );

    // -------- errors --------

    error NotOwner();
    error InsufficientBalance();
    error InsufficientAllowance();
    error InvalidRecipient();
    error Reentrant();
    error ZeroTokensPerSlugg();
    error ZeroTreasury();       // initial supply must have a non-zero recipient
    error NotSluggHolder();
    error NotClaimedHolder();
    error ClaimedNotConfigured();
    error TreasuryNotSet();
    error TransferDisabled();   // ERC-721 transfer not allowed; use ERC-20
    error WrongWrapFee();
    error WrongUnwrapFee();
    error TreasuryRejectedEth();
    error RouterAlreadySet();
    error RouterNotSet();
    error ZeroAddress();
    error ZeroCount();
    error SlippageTooHigh();    // maxSlippageBps > 500 (5% hard cap)
    error SlippageExceeded();   // round-trip returned less USLUG than threshold
    error EthLegFailed();       // sell leg returned 0 ETH (or buy leg overshot; defense-in-depth)
    error InsufficientBuffer(); // callHook caller didn't budget the worst-case slippage buffer
    error EthRefundFailed();    // dust refund to caller after callHook failed
    error SeedSourceAlreadySet();
    error RendererAlreadySet();
    error ClaimedNftAlreadySet();
    error WrapFeeTooHigh();         // setWrapFee above hard cap
    error UnwrapFeeTooHigh();       // setUnwrapFee above hard cap
    error CannotUnskip();           // setSkip is add-only — once true, stays true
    error NotPendingTreasury();     // 2-step treasury accept by the wrong address
    error BatchTooLarge();          // _move would mint more than MAX_MINTS_PER_TX
    error NotYetRevealable();       // reveal called before mintBlock + REVEAL_DELAY
    error AlreadyRevealed();        // reveal called twice for the same id
    error NotMinted();              // reveal called for a non-existent slugg
    error WrapTooSoon();            // wrap called before slugg passed MIN_WRAP_AGE

    /// @dev Hard ceiling on `maxSlippageBps` for callHook. 500 = 5%. Caller-
    /// supplied; UI defaults to 100 (1%) but we enforce the ceiling on-chain.
    uint16 public constant MAX_SLIPPAGE_BPS = 500;

    /// @dev Hard cap on wrap/unwrap fees (in wei). Prevents owner from later
    /// griefing users by setting wrap fee to 100 ETH. ~0.1 ETH is generous.
    uint256 public constant MAX_WRAP_FEE_WEI = 0.1 ether;

    /// @dev Maximum number of sluggs minted in a single _move call.
    /// Caps atomic batch rarity-extraction: an attacker can still mint a
    /// batch and pick rares, but can't drain the variance space in one tx.
    /// 25 is roughly 4 ETH at typical mint price — significant capital
    /// per attempt while still letting normal whales buy a sensible amount.
    uint256 public constant MAX_MINTS_PER_TX = 25;

    /// @dev Minimum block age before a slugg can be wrapped (extracted to
    /// the standalone ERC-721). Combined with the deferred-reveal delay,
    /// prevents single-tx atomic mint→inspect→wrap-the-rare→sell-rest
    /// extraction. The attacker has to wait MIN_WRAP_AGE blocks before
    /// they can pull the rare out — during which other extractors can
    /// front-run them and the floor can recover.
    uint64 public constant MIN_WRAP_AGE = 32;

    /// @dev Two-step treasury transfer (matches the hook's owner pattern).
    /// Prevents typo'd treasury addresses from permanently routing fees
    /// to a black hole.
    address payable public pendingTreasury;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Inline reentrancy guard. Defense-in-depth on wrap/unwrap/callHook;
    /// callHook in particular re-enters through PoolManager's unlock callback
    /// twice (sell, then buy) so the guard is load-bearing there.
    uint8 private _locked = 1;
    modifier nonReentrant() {
        if (_locked != 1) revert Reentrant();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(
        ISeedSource _seed,
        address payable _treasury,
        uint256 _maxSluggs,
        uint256 _tokensPerSlugg
    ) {
        if (_tokensPerSlugg == 0) revert ZeroTokensPerSlugg();
        // Initial supply (maxSluggs * tokensPerSlugg) lands in _treasury — must
        // be a real address. setTreasury(0) afterwards is fine and explicitly
        // disables the wrap/unwrap fee path.
        if (_treasury == address(0)) revert ZeroTreasury();
        owner          = msg.sender;
        seed           = _seed;
        treasury       = _treasury;
        maxSluggs      = _maxSluggs;
        tokensPerSlugg = _tokensPerSlugg;
        totalSupply    = _maxSluggs * _tokensPerSlugg;
        skipSluggs[_treasury]    = true;
        // The token itself holds USLUG in transit during wrap()/callHook(); it
        // must never auto-mint sluggs to itself. Setting at construction is
        // the safe place — the contract's own address cannot host an NFT id.
        skipSluggs[address(this)] = true;
        balanceOf[_treasury]  = totalSupply;
        emit Transfer(address(0), _treasury, totalSupply);
    }

    // -------- admin --------

    // setSeedSource removed: `seed` is immutable, set in constructor.
    // No post-deploy mutation of the randomness source is possible.

    /// @notice Add an address to the skipSluggs set. ADD-ONLY: once true, an
    /// address cannot be flipped back to false. Without this guard a
    /// compromised owner could un-skip the PoolManager (causing it to
    /// accumulate ungettable NFTs from sell-leg settles) or un-skip the
    /// treasury (breaking initial supply distribution semantics).
    /// Passing v=false reverts.
    function setSkip(address a, bool v) external onlyOwner {
        if (!v) revert CannotUnskip();
        if (skipSluggs[a]) return;  // idempotent
        skipSluggs[a] = true;
        emit SkipSet(a, true);
    }

    /// @notice One-shot: set the in-404 renderer. Reverts on second call.
    /// Without this guard, a compromised owner could swap the renderer to one
    /// that returns altered SVGs (visual vandalism, fake "rare" art appearing
    /// on commons). After the initial wire-up at deploy, the renderer is
    /// permanently pinned.
    function setRenderer(IUSluggRenderer r) external onlyOwner {
        if (address(renderer) != address(0)) revert RendererAlreadySet();
        renderer = r;
        emit RendererSet(address(r));
    }

    /// @notice One-shot: set the standalone USluggClaimed ERC-721. Reverts on
    /// second call. Without this guard, a compromised owner could swap the
    /// claimed-NFT contract to one that hands out attacker-owned tokens on
    /// wrap() / steals tokens on unwrap(). Pinned at deploy.
    function setClaimedNft(IUSluggClaimed c) external onlyOwner {
        if (address(claimedNft) != address(0)) revert ClaimedNftAlreadySet();
        claimedNft = c;
        emit ClaimedNftSet(address(c));
    }

    /// @notice Owner passthrough so the Claimed ERC-721's renderer can be swapped.
    function setClaimedRenderer(address newRenderer) external onlyOwner {
        require(address(claimedNft) != address(0), "claimedNft not configured");
        IUSluggClaimedAdmin(address(claimedNft)).setRenderer(IUSluggRenderer(newRenderer));
    }

    /// @notice Owner passthrough for EIP-2981 royalty config on USluggClaimed.
    /// Marketplaces will pay this percentage of secondary sales to `recipient`.
    function setClaimedRoyalty(address recipient, uint96 bps) external onlyOwner {
        require(address(claimedNft) != address(0), "claimedNft not configured");
        IUSluggClaimedAdmin(address(claimedNft)).setRoyalty(recipient, bps);
    }

    /// @notice Step 1 of two-step treasury transfer. Owner proposes the new
    /// treasury; no effect until acceptTreasury() is called from that address.
    /// Prevents a typo from permanently routing fees to an unowned address.
    /// Pass address(0) to cancel a previously-proposed transfer.
    function proposeTreasury(address payable t) external onlyOwner {
        pendingTreasury = t;
        emit TreasuryProposed(treasury, t);
    }

    /// @notice Step 2: pendingTreasury claims the role. Owner-typo'd
    /// addresses can never accept, so misfires don't brick fee flow.
    function acceptTreasury() external {
        if (msg.sender != pendingTreasury) revert NotPendingTreasury();
        treasury = pendingTreasury;
        delete pendingTreasury;
        emit TreasurySet(treasury);
    }

    function setWrapFee(uint256 feeWei) external onlyOwner {
        if (feeWei > MAX_WRAP_FEE_WEI) revert WrapFeeTooHigh();
        wrapFeeWei = feeWei;
        emit WrapFeeSet(feeWei);
    }

    function setUnwrapFee(uint256 feeWei) external onlyOwner {
        if (feeWei > MAX_WRAP_FEE_WEI) revert UnwrapFeeTooHigh();
        unwrapFeeWei = feeWei;
        emit UnwrapFeeSet(feeWei);
    }

    /// @notice One-shot pin of the locked-pool swap router used by callHook.
    /// After this returns, the token has approved `router` for max USLUG (so
    /// `callHook` can sell without re-approving every call), and the router
    /// is added to skipSluggs (it's transit, not a holder). One-shot to prevent
    /// late hijack: if owner is later compromised, they can't swap routers
    /// underneath users.
    function setSwapRouter(address router) external onlyOwner {
        if (_routerSet) revert RouterAlreadySet();
        if (router == address(0)) revert ZeroAddress();
        _routerSet = true;
        swapRouter = router;
        skipSluggs[router] = true;       // router is transit
        // Set max approval once. allowance[address(this)][router] is stored
        // directly; emit Approval so indexers (and the router's own
        // transferFrom) see the standard ERC-20 wiring.
        allowance[address(this)][router] = type(uint256).max;
        emit Approval(address(this), router, type(uint256).max);
        emit SkipSet(router, true);
        emit SwapRouterSet(router);
    }

    // -------- ERC-20 --------

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            if (a < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = a - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        // Reject address(0) — minting an NFT to zero would store ownerOf[id]=0
        // (indistinguishable from never-minted) and bloat _inventory[address(0)].
        if (to == address(0)) revert InvalidRecipient();
        uint256 fb = balanceOf[from];
        if (fb < amount) revert InsufficientBalance();

        uint256 fromWholeBefore = fb / tokensPerSlugg;
        uint256 toWholeBefore   = balanceOf[to] / tokensPerSlugg;

        unchecked {
            balanceOf[from] = fb - amount;
            balanceOf[to]  += amount;
        }

        uint256 fromWholeAfter = balanceOf[from] / tokensPerSlugg;
        uint256 toWholeAfter   = balanceOf[to]   / tokensPerSlugg;

        if (!skipSluggs[from] && fromWholeAfter < fromWholeBefore) {
            // Lossy burn: if the holder's whole-balance dropped by `lose` but
            // their inventory has fewer NFTs than `lose`, burn what they have
            // and let the rest just be a balance decrement. This handles the
            // post-redesign case where USLUG can be transferred WITHOUT a
            // matching NFT mint (auto-mint is gated on swapFiredThisTx, so
            // p2p / faucet / airdrop USLUG arrives without sluggs). Without
            // this, those holders couldn't sell their USLUG — `_inventory.pop`
            // on an empty array would underflow and brick transfers.
            uint256 lose = fromWholeBefore - fromWholeAfter;
            uint256 invLen = _inventory[from].length;
            uint256 toBurn = lose < invLen ? lose : invLen;
            for (uint256 i; i < toBurn; ++i) {
                uint256 last = _inventory[from].length - 1;
                uint256 id   = _inventory[from][last];
                _inventory[from].pop();
                delete sluggs[id];
                delete ownerOf[id];
                emit SluggBurned(id, from);
                emit Transfer721(from, address(0), id);
            }
        }

        // Receive-side auto-mint is gated on swapFiredThisTx() — only
        // USLUG that arrived via a locked-pool afterSwap (path A or path
        // C round-trip) materializes sluggs. Other deliveries (direct
        // transfer, faucet, airdrop, aggregator without our pool) just
        // land as balance; the holder can call callHook() later to
        // materialize sluggs with a fresh seed.
        if (!skipSluggs[to] && toWholeAfter > toWholeBefore && seed.swapFiredThisTx()) {
            uint256 gain = toWholeAfter - toWholeBefore;
            // Cap atomic batch extraction: an attacker minting hundreds in one
            // tx to grind rares is a known uPEG-style vector. Reverting here
            // forces them to spread across multiple txs (each subject to
            // independent inclusion + recompete from other extractors).
            if (gain > MAX_MINTS_PER_TX) revert BatchTooLarge();
            uint64 mintBlk = uint64(block.number);
            for (uint256 i; i < gain; ++i) {
                uint256 id = nextSluggId++;
                // No seed yet — set to bytes32(0). reveal() will compute the
                // real seed from blockhash(mintBlock + REVEAL_DELAY) once the
                // reveal block has been mined. Builders cannot predict that
                // hash from the mint block.
                sluggs[id]  = Slugg({ seed: bytes32(0), originalMinter: to, mintBlock: mintBlk });
                ownerOf[id] = to;
                _inventory[to].push(id);
                emit SluggMinted(id, to, mintBlk);
                emit Transfer721(address(0), to, id);
            }
        }

        emit Transfer(from, to, amount);
    }

    // -------- callHook: materialize sluggs from already-held USLUG --------

    /// @notice Pull `count * tokensPerSlugg` USLUG from caller, round-trip it
    /// through the locked pool (sell → buy), and mint `count` sluggs with the
    /// fresh post-swap seed. The caller pays ~2x pool fees + slippage; the
    /// real economic cost prevents cheap seed grinding.
    ///
    /// Slippage: caller-supplied bps; UI default is 100 (1%). On-chain hard
    /// cap is 500 (5%) — anything higher reverts immediately.
    ///
    /// All-or-nothing: any leg failure (sell revert, buy revert, slippage
    /// exceeded) reverts the entire tx, so the caller's USLUG is restored
    /// atomically and no partial state escapes.
    function callHook(uint256 count, uint256 maxSlippageBps) external nonReentrant {
        if (count == 0) revert ZeroCount();
        if (maxSlippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh();
        address router = swapRouter;
        if (router == address(0)) revert RouterNotSet();

        uint256 amountIn = count * tokensPerSlugg;

        // ---- Snapshot ETH balance at the very top so leftover dust from the
        // exact-output buy refund (USluggSwap returns the unspent portion to
        // its `p.sender`, which is this contract) can be forwarded to the
        // caller at the end. Anything already held here pre-call is left
        // untouched — only the post-buy delta gets refunded.
        uint256 ethBefore = address(this).balance;

        // ---- Slippage buffer precondition. Without this, a caller with
        // exactly `(existingSluggs + count) * TPS` USLUG could survive the
        // round-trip with `count` new sluggs but a balance that has eroded
        // below `inventory.length * TPS`, permanently breaking the
        // `inventory.length <= balance/TPS` invariant. Require the caller to
        // budget the worst-case slippage buffer up front:
        //   existing-sluggs-coverage + new-sluggs-coverage + maxSlippageBps buffer
        uint256 ownedNow = _inventory[msg.sender].length;
        uint256 required = (ownedNow + count) * tokensPerSlugg
                         + (amountIn * maxSlippageBps) / 10_000;
        if (balanceOf[msg.sender] < required) revert InsufficientBuffer();

        // ---- Pull USLUG from caller via direct balance manipulation. We
        // bypass _move because: (a) the caller might not have inventory NFTs
        // that match this balance crossing (post-redesign, USLUG can exist
        // without sluggs), so the lossy-burn path would fire — but we don't
        // want to burn random user inventory; (b) address(this) is skipSluggs
        // anyway. We only emit the standard ERC-20 Transfer event for indexers.
        unchecked {
            balanceOf[msg.sender] -= amountIn;
            balanceOf[address(this)] += amountIn;
        }
        emit Transfer(msg.sender, address(this), amountIn);

        // ---- Round-trip: sell → buy. Both legs trigger afterSwap on the
        // locked pool, so currentSeed advances twice. We use ETH balance
        // deltas (not absolutes) so any pre-existing dust on this contract
        // can never be swept into the round-trip.

        // Sell leg. minEthOut=1: we don't enforce per-leg slippage here
        // (the round-trip slippage check at the end is the user's protection).
        // The router pulls USLUG via transferFrom against the max allowance
        // we set in setSwapRouter.
        uint256 ethOut = IUSluggSwapRouter(router).sell(amountIn, 1, block.timestamp);
        uint256 ethGot;
        unchecked { ethGot = address(this).balance - ethBefore; }
        // Sanity check: ethGot must be > 0 to fund the buy leg. ethOut from
        // the router should equal ethGot, but we use the delta as the source
        // of truth (defends against any accounting drift inside the router).
        if (ethGot == 0 || ethOut == 0) revert EthLegFailed();

        // Buy leg: exact-output for `expected` USLUG, max-input ethGot. Pool
        // fills at the spot price; if ethGot is insufficient, this reverts
        // (MaxInputExceeded) and unwinds the whole tx. The exact-output
        // semantics also automatically enforce the round-trip slippage:
        // we receive exactly `expected` USLUG or the swap reverts.
        uint256 expected = (amountIn * (10_000 - maxSlippageBps)) / 10_000;

        uint256 usluggBefore = balanceOf[address(this)];
        IUSluggSwapRouter(router).buy{value: ethGot}(expected, ethGot, block.timestamp);
        uint256 usluggBack;
        unchecked { usluggBack = balanceOf[address(this)] - usluggBefore; }

        // Belt-and-suspenders slippage check. Exact-output buy() means
        // usluggBack should equal `expected` exactly; we check >= in case any
        // rounding inside the router ever returns slightly more (a router
        // upgrade quirk shouldn't break us).
        if (usluggBack < expected) revert SlippageExceeded();

        // ---- Return the round-tripped USLUG to the caller via direct
        // balance manipulation. Same reasoning as the pull above: avoid
        // _move's auto-mint because the caller's whole-balance crossing
        // here would fire the receive branch with stale/unwanted state.
        // We mint sluggs ourselves below using the post-second-swap seed.
        unchecked {
            balanceOf[address(this)] -= usluggBack;
            balanceOf[msg.sender]    += usluggBack;
        }
        emit Transfer(address(this), msg.sender, usluggBack);

        // ---- Mint `count` sluggs to caller. Same deferred-reveal model as
        // _move: store mintBlock, set seed=bytes32(0), reveal later via
        // blockhash(mintBlock + REVEAL_DELAY) which the builder of the mint
        // block cannot control.
        if (count > MAX_MINTS_PER_TX) revert BatchTooLarge();
        uint64 mintBlk = uint64(block.number);
        for (uint256 i; i < count; ++i) {
            uint256 id = nextSluggId++;
            sluggs[id]  = Slugg({ seed: bytes32(0), originalMinter: msg.sender, mintBlock: mintBlk });
            ownerOf[id] = msg.sender;
            _inventory[msg.sender].push(id);
            emit SluggMinted(id, msg.sender, mintBlk);
            emit Transfer721(address(0), msg.sender, id);
        }

        // ---- Forward any ETH dust the buy leg refunded (USluggSwap.buy is
        // exact-output and refunds the unspent portion of `ethGot` to its
        // p.sender, which is this contract). Pre-existing balance held by the
        // contract before this call is preserved by anchoring on `ethBefore`.
        uint256 leftover;
        unchecked { leftover = address(this).balance - ethBefore; }
        if (leftover > 0) {
            (bool ok, ) = msg.sender.call{value: leftover}("");
            if (!ok) revert EthRefundFailed();
        }

        emit CallHookCompleted(msg.sender, amountIn, ethGot, usluggBack, count);
    }

    /// @notice ETH receiver for callHook's sell leg (router refunds ETH back
    /// to msg.sender of sell, which is this contract). Permissive — any
    /// non-router sender can also send ETH, but `callHook` only spends ETH
    /// via the cached delta `ethGot = balanceAfter - balanceBefore`, so dust
    /// from third parties cannot be swept into a round-trip.
    receive() external payable {}

    // -------- reveal: lock in the deferred-randomness seed --------

    /// @notice Reveal the seed for a slugg. Anyone can call (no permission)
    /// once block.number > mintBlock + REVEAL_DELAY. The seed is computed
    /// from blockhash(mintBlock + REVEAL_DELAY), which the builder of the
    /// mint block could not predict (they would have to also build the
    /// reveal block to control it — vanishingly unlikely).
    ///
    /// Stale-blockhash fallback: if the reveal block is more than 256 blocks
    /// in the past, blockhash() returns 0. In that case we fall back to
    /// blockhash(block.number - 1) so the seed is still deterministic and
    /// anyone-callable; the worst case is a rare slugg whose seed depends
    /// on whoever first calls reveal() in the late-reveal window.
    function reveal(uint256 id) external {
        Slugg storage s = sluggs[id];
        if (s.mintBlock == 0) revert NotMinted();
        if (s.seed != bytes32(0)) revert AlreadyRevealed();
        uint64 revealBlock = s.mintBlock + REVEAL_DELAY;
        if (block.number <= revealBlock) revert NotYetRevealable();

        bytes32 h = blockhash(revealBlock);
        if (h == bytes32(0)) {
            // >256 blocks since reveal block — use latest available hash as fallback
            h = blockhash(block.number - 1);
            // block.number >= 1 guaranteed inside any tx, so blockhash(N-1) is non-zero
        }
        bytes32 newSeed = keccak256(abi.encode(h, id, s.originalMinter));
        s.seed = newSeed;
        emit SluggRevealed(id, newSeed);
    }

    /// @notice Batch reveal helper. Same semantics as reveal(id) per id;
    /// simply loops. Caller pays gas for each (about ~30k each).
    function revealMany(uint256[] calldata ids) external {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            Slugg storage s = sluggs[id];
            if (s.mintBlock == 0 || s.seed != bytes32(0)) continue; // skip non-existent / already-revealed
            uint64 revealBlock = s.mintBlock + REVEAL_DELAY;
            if (block.number <= revealBlock) continue; // skip too-early in batch
            bytes32 h = blockhash(revealBlock);
            if (h == bytes32(0)) h = blockhash(block.number - 1);
            bytes32 newSeed = keccak256(abi.encode(h, id, s.originalMinter));
            s.seed = newSeed;
            emit SluggRevealed(id, newSeed);
        }
    }

    // -------- views --------

    function inventoryOf(address a) external view returns (uint256[] memory) {
        return _inventory[a];
    }

    function sluggsOwned(address a) external view returns (uint256) {
        return _inventory[a].length;
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        Slugg memory c = sluggs[id];
        return renderer.tokenURI(id, c.seed);
    }

    function nftBalanceOf(address a) external view returns (uint256) {
        return _inventory[a].length;
    }

    // -------- ERC-721 transfer surface (intentionally disabled) --------
    // The NFT and the underlying ERC-20 are joined at the hip. To trade a
    // specific Slugg, either move the whole USLUG token via ERC-20 functions,
    // or wrap() it into a standalone USluggClaimed ERC-721.

    function getApproved(uint256) external pure returns (address) { return address(0); }
    function isApprovedForAll(address, address) external pure returns (bool) { return false; }
    function approveNft(address, uint256) external pure { revert TransferDisabled(); }
    function setApprovalForAll(address, bool) external pure { revert TransferDisabled(); }
    function transferFrom(address, address, uint256, bytes calldata) external pure { revert TransferDisabled(); }
    function safeTransferFrom(address, address, uint256) external pure { revert TransferDisabled(); }
    function safeTransferFrom(address, address, uint256, bytes calldata) external pure { revert TransferDisabled(); }

    // -------- wrap / unwrap (standalone ERC-721 wrapping with treasury fee) --------

    /// @notice Wrap a Slugg out of the 404 surface and into the standalone
    /// USluggClaimed ERC-721. Burns the in-404 slugg, locks 1 USLUG inside
    /// this contract, and mints a fresh USluggClaimed token to the caller.
    /// Pays `wrapFeeWei` ETH to treasury.
    function wrap(uint256 id) external payable nonReentrant returns (uint256 claimedId) {
        if (address(claimedNft) == address(0)) revert ClaimedNotConfigured();
        if (ownerOf[id] != msg.sender) revert NotSluggHolder();
        if (treasury == address(0) && wrapFeeWei > 0) revert TreasuryNotSet();
        if (msg.value != wrapFeeWei) revert WrongWrapFee();
        if (balanceOf[msg.sender] < tokensPerSlugg) revert InsufficientBalance();

        Slugg memory c = sluggs[id];
        // MIN_WRAP_AGE prevents single-tx atomic mint→inspect→wrap-the-rare
        // extraction: the attacker has to wait MIN_WRAP_AGE blocks before
        // pulling the rare into the standalone ERC-721, during which time
        // other extractors and the market can react. Combined with the
        // deferred reveal, the attacker doesn't even know which one is rare
        // until reveal time has passed.
        if (block.number < uint256(c.mintBlock) + MIN_WRAP_AGE) revert WrapTooSoon();
        // Wrapped sluggs must have a real seed — wrapping an unrevealed slugg
        // would freeze the original art identity to bytes32(0) and break the
        // wrap/unwrap round-trip. Holder must reveal() first.
        if (c.seed == bytes32(0)) revert NotYetRevealable();

        // ---- EFFECTS: all internal state writes (and their describing events)
        // happen before any external interaction.
        _removeFromInventory(msg.sender, id);
        delete sluggs[id];
        delete ownerOf[id];

        unchecked {
            balanceOf[msg.sender] -= tokensPerSlugg;
            balanceOf[address(this)] += tokensPerSlugg;
        }
        emit Transfer(msg.sender, address(this), tokensPerSlugg);
        emit SluggBurned(id, msg.sender);
        emit Transfer721(msg.sender, address(0), id);

        // ---- INTERACTIONS: external calls last.
        if (msg.value > 0) {
            (bool ok, ) = treasury.call{value: msg.value}("");
            if (!ok) revert TreasuryRejectedEth();
            emit WrapFeePaid(msg.sender, treasury, msg.value);
        }

        claimedId = claimedNft.mint(msg.sender, c.seed, id);
        emit SluggWrapped(msg.sender, id, claimedId, msg.value);
    }

    /// @notice Inverse of wrap(): burn a USluggClaimed token, return 1 USLUG
    /// to the caller, and re-mint a 404 slugg with the same seed (preserves
    /// the wrapped art identity).
    function unwrap(uint256 claimedId) external payable nonReentrant returns (uint256 newSluggId) {
        if (address(claimedNft) == address(0)) revert ClaimedNotConfigured();
        if (claimedNft.ownerOf(claimedId) != msg.sender) revert NotClaimedHolder();
        if (treasury == address(0) && unwrapFeeWei > 0) revert TreasuryNotSet();
        if (msg.value != unwrapFeeWei) revert WrongUnwrapFee();

        // Reads (staticcalls). Cached before effects so the CEI ordering below is clean.
        (bytes32 oldSeed,,) = claimedNft.claimed(claimedId);

        // ---- EFFECTS: all internal state writes happen here, before any external mutation.
        unchecked {
            balanceOf[address(this)] -= tokensPerSlugg;
            balanceOf[msg.sender]    += tokensPerSlugg;
        }
        emit Transfer(address(this), msg.sender, tokensPerSlugg);

        newSluggId = nextSluggId++;
        // The unwrapped slugg keeps the original wrapped art identity
        // (oldSeed); it doesn't go through the deferred-reveal flow because
        // the seed is already known. mintBlock still gets the current block
        // for accounting; reveal() would be a no-op since seed != 0.
        sluggs[newSluggId] = Slugg({
            seed:           oldSeed,
            originalMinter: msg.sender,
            mintBlock:      uint64(block.number)
        });
        ownerOf[newSluggId] = msg.sender;
        _inventory[msg.sender].push(newSluggId);
        emit SluggMinted(newSluggId, msg.sender, uint64(block.number));
        emit SluggRevealed(newSluggId, oldSeed);
        emit Transfer721(address(0), msg.sender, newSluggId);
        emit SluggUnwrapped(msg.sender, claimedId, newSluggId);

        // ---- INTERACTIONS: external calls last. If either reverts, the entire
        // tx unwinds and all state writes above are rolled back atomically.
        claimedNft.burn(claimedId);

        if (msg.value > 0) {
            (bool ok, ) = treasury.call{value: msg.value}("");
            if (!ok) revert TreasuryRejectedEth();
            emit WrapFeePaid(msg.sender, treasury, msg.value);
        }
    }

    function _removeFromInventory(address holder, uint256 id) internal {
        uint256[] storage inv = _inventory[holder];
        uint256 n = inv.length;
        for (uint256 i = 0; i < n; i++) {
            if (inv[i] == id) {
                inv[i] = inv[n - 1];
                inv.pop();
                return;
            }
        }
        revert NotSluggHolder();
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7  // ERC-165
            || id == 0x36372b07  // ERC-20 (loose)
            || id == 0x80ac58cd  // ERC-721
            || id == 0x5b5e139f; // ERC-721 Metadata
    }
}
