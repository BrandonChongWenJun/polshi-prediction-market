# Requirement checklist — Option 4: Prediction Market

Status legend: **Done** = implemented, tested and reachable from the UI · **Partial** = implemented with a stated gap ·
**Not done** = not implemented. Contract paths are relative to `contracts/`; tests live in `contracts/test/`
(`PM.*` = `PredictionMarket.*.t.sol`). "e2e" = `e2e/smoke_test.py` step number (see its docstring / screenshots).

## Core feature requirements

| # | Requirement | Status | Where implemented (file + function) | Tests proving it | Notes |
|---|---|---|---|---|---|
| 1 | **Market creation**: open a topic with a question and outcome options | Done | `src/PredictionMarket.sol` `createMarket`, `_validateCreate`, `_storeMarket`; UI `frontend/js/views/create.js` | `PM.Create`: `test_createBinaryMarket_uniformOdds`, `test_createMultiOutcome_withOdds`, `test_createEightOutcomes`, `test_revert_outcomeCount`, `test_revert_invalidText`; e2e [6] | 2–8 outcomes, question ≤ 280 bytes, optional category |
| 2 | Market creation: **timestamps** | Done | `createMarket` (`closeTime`, `resolutionTime`), `_phase` | `test_revert_invalidTimes`, `test_resolutionTimeEqualToCloseTime_isAllowed`, `PM.Resolution` `test_phases` | UI validates against chain time |
| 3 | Market creation: **arbitrator identity** | Done | `createMarket` (`arbitrator`), `reportOutcome` (only that address) | `test_revert_zeroArbitrator`, `test_revert_report_notArbitrator`, `Security` `test_arbitratorCannotReportForOtherMarkets` | any address (EOA, multisig, contract such as the ReputationOracle) |
| 4 | Market creation: collateral token, initial liquidity, initial odds, fee | Done | `createMarket`, `_initialPool`, `setCollateral` (allow-list + min liquidity) | `test_createWithInitialOdds_setsPricesAndReturnsTokens`, `test_revert_invalidOdds`, `test_revert_oddsRoundPoolBalanceToZero`, `test_revert_liquidityTooLow`, `test_revert_feeTooHigh`, `test_revert_collateralNotAllowed`, `PM.Fuzz` `testFuzz_initialOdds`; e2e [6], [7] (WETH market opened at 70/30 odds) | creator becomes first LP |
| 5 | **Trading & minting: place bets, receive outcome tokens** | Done | `buy` (FPMM, ERC-1155 `_mint`), `splitPosition`/`mergePositions` (complete sets), `positionId` | `PM.Trading`: `test_buy_knownValues`, `test_splitAndMerge`, `test_buy_zeroFeeMarket`, `test_erc1155TransfersKeepBacking`; e2e [2] (buy), [8] (mint + merge complete sets) | outcome tokens are ERC-1155 ids `(marketId << 8) \| outcome` |
| 6 | **Dynamically derived market odds** | Done | `src/libraries/FpmmMath.sol` `prices`, `calcBuyAmount`; `getPrices`, `getMarket` | `FpmmMath` `testFuzz_buyRaisesPrice`, `test_prices_binaryAndUniform`; `test_buy_averagePriceBetweenOldAndNewSpot`, `test_multiOutcome_buyMovesOnlyUpTheBoughtOutcome`; e2e [2] (probability rises after a buy) | Gnosis FPMM, justification in README Q1 |
| 7 | Sell back before close | Done | `sell` (exact input, `FpmmMath.calcSellGross` binary search), `calcSellReturn` | `test_sell_exactInput_matchesQuote`, `test_sell_roundTripLosesOnlyFeesAndRounding`, `test_revert_sell_afterClose`, `FpmmMath` `testFuzz_sellGrossIsMaximal`; e2e [3] | |
| 8 | Slippage protection (min out / max cost) | Done | `buy(minSharesOut)`, `sell(minCollateralOut)`, `addLiquidity(minShares)`, `removeLiquidity(minCollateralOut)` | `test_revert_buy_slippage`, `test_revert_buy_frontRunTriggersSlippage`, `test_revert_sell_slippage`, `test_revert_addLiquidity`, `test_revert_removeLiquidity` | UI tolerance selector 0.5–5 % |
| 9 | Prices sum to ~1 | Done | `FpmmMath.prices` | `testFuzz_pricesSumToOne`, `invariant_pricesAndPool`, `test_createMultiOutcome_withOdds` | exact up to 1 wei per outcome |
| 10 | **Market always solvent** (collateral ≥ max payout), proven with invariants | Done | complete-set accounting in every function; rounding rules (README Q2) | `invariant_collateralConservation`, `invariant_solvency`, `invariant_lpAccounting`, `testFuzz_randomTradesKeepSolvency`, `testFuzz_resolutionPayoutsNeverExceedCollateral`, `test_fullLifecycle_contractEndsWithOnlyDust` | identity `supply_i + pool_i == collateralLocked` |
| 11 | **Resolution: after the event time only the arbitrator can report** | Done | `reportOutcome` | `test_report_byArbitrator`, `test_revert_report_tooEarly`, `test_revert_report_notArbitrator`, `test_revert_report_invalidIndex_twice_missing`; e2e [9] | window `[resolutionTime, +7 days)` |
| 12 | **Winners redeem 1 collateral per winning share** | Done | `redeem`, `_payoutValue`, `getUserPosition.redeemable` | `test_redeem_winnerGetsOnePerShare_loserGetsNothing`, `test_redeem_burnsLosingTokensToo`, `test_revert_redeem_beforeResolution`; e2e [9] | |
| 13 | Invalid / cancelled result with pro-rata refund | Done | `reportOutcome(INVALID_OUTCOME=255)`, `_payoutValue` (1/N per share) | `test_invalid_paysOneOverNPerShare`, `test_invalid_completeSetHolderIsMadeWhole`, `test_fullLifecycle_invalid_multiOutcome_weth`; e2e [10] | 1/N per share (README Q5 explains why not cost basis) |
| 14 | Arbitrator never reports → timeout → invalid | Done | `resolveAfterTimeout` (permissionless after 7 days) | `test_timeout_resolvesInvalid`, `test_revert_timeout_afterReport`, `test_revert_report_afterWindow`; e2e [10] | |
| 15 | Liquidity providers can withdraw what they are owed | Done | `addLiquidity`, `removeLiquidity` (merge before / value after resolution), `claimFees`, fee accumulator `_checkpointFees`/`_takeFees` | `PM.Liquidity` (16 tests, e.g. `test_removeLiquidity_afterResolution_paysValue`, `test_fees_splitProRataBetweenLps`, `test_fees_neverExceedPoolWithOddShares`), `testFuzz_addRemoveLiquidity_noValueExtraction`; e2e [8] (add/remove), [13] (claim fees) | exits are never pausable |
| 16 | Oracle problem discussed (trusted arbitrator vs staking/disputes) | Done | `README.md` §3 Q4, Q9, §8 | — | |

## Bonus features

| # | Requirement | Status | Where implemented (file + function) | Tests proving it | Notes |
|---|---|---|---|---|---|
| B1 | **Secondary (P2P) market before resolution**: escrowed limit orders, partial fills, cancellation | Done | `src/OrderBook.sol` `placeOrder`, `fillOrder`, `cancelOrder`, `getMarketOrders`, `onERC1155Received`; UI order-book tab in `views/market.js` | `OrderBook.t.sol` (22 tests incl. `test_ask_partialAndFullFill`, `test_bid_partialFillsAndDustRefund`, `test_expiry`, `test_tradingAfterAmmCloseButBeforeResolution_thenBlocked`, 2 fuzz), `invariant_escrowMatchesOpenOrders`, `invariant_conservation`, `Security` `test_reentrancy_orderBookCancelHookCannotDoubleCancel`; e2e [4], [5] | open until resolution (also after AMM close); optional expiry |
| B2 | **Multi-asset collateral** incl. 6-decimal USDT (decimals handled end to end, UI included) and WETH | Done | `setCollateral` allow-list, `_pullCollateral` (SafeERC20 + fee-on-transfer check); `src/tokens/MockUSDT.sol` (Tether semantics), `MockERC20.sol` (DAI 18 dp), `WETH9.sol`; UI collateral selector/filter, `format.js`, `chain.js ensureAllowance` | `test_decimals_sameEconomicsFor6And18Decimals`, `test_fullLifecycle_invalid_multiOutcome_weth`, `test_multiCollateral_wethMarketOrders`, `Tokens.t.sol` (9), `test_revert_feeOnTransferCollateral`, `FeeToggleTest`, invariants run over USDT/DAI/WETH markets; e2e [6] (USDT), [7] (WETH) | |
| B3 | **Reputation-weighted voting** resolution mode: registered reporters, reputation earned/lost, voting window, quorum, tie/no-quorum handling | Done (not stake-backed) | `src/ReputationOracle.sol` `registerReporter`, `removeReporter`, `vote`, `finalize`, `_tallyResult`, `_updateReputations`, `getRound`, `getVotes`, `getReporters`; UI vote panel (`views/market.js`), `views/reporters.js` | `ReputationOracle.t.sol` (25 tests: consensus, weighting, INVALID vote, no quorum → extension, late extension still a full period, extension capped before the deadline, tie → extension → invalid, tie broken, quorum snapshot, void paths, reputation cap, slash to zero), `invariant_reputationAccounting`, `invariant_roundsConsistentWithMarkets`; e2e [7] (create a vote-resolved market), [11] (vote, fast-forward, finalize, reputation update, admin registers a reporter) | Staking of real tokens (marked "optional") is **not** implemented; voting is open, not commit-reveal (README §8) |

## Frontend requirements

| # | Requirement | Status | Where | Verified by | Notes |
|---|---|---|---|---|---|
| F1 | Market list with live odds | Done | `views/markets.js` | e2e [1], `01_markets.png` | filters by status / collateral / text |
| F2 | Market detail with probability chart over time (from events) | Done | `views/market.js`, `chart.js`, `data.js fetchHistory` (`PoolUpdated` logs) | e2e [2], `02_trade_quote.png`, `14_dark_market.png` | crosshair tooltip, 1D/1W/1M/All, table view, keyboard |
| F3 | Buy / sell with price-impact preview | Done | `views/market.js requote/submitTrade` | e2e [2], [3] | shares, avg price, impact, new probability, fee, payout |
| F4 | My positions | Done | position panel (`paintPosition`), `views/portfolio.js` | e2e [13], `13_portfolio.png` | |
| F5 | Create-market form | Done | `views/create.js` | e2e [6] (USDT, 3 outcomes, arbitrator), [7] (WETH, reputation vote, custom odds), `06_created_market.png`, `07b_weth_vote_market.png` | approve + create, redirects to the new market |
| F6 | Arbitrator / voter resolution panel, redeem | Done | `views/market.js paintResolution/voteHTML` | e2e [9], [10], [11] | report, vote, finalize, timeout, redeem |
| F7 | P2P share order book | Done | order-book tab in `views/market.js` | e2e [4], [5] | |
| F8 | Collateral selector | Done | create form token picker, markets filter, wallet page | e2e [6], [7] | |
| F9 | Wallet mode 1: MetaMask / EIP-1193 (right chain, account/chain changes) | Done | `wallet.js connectInjected/ensureChain/attachInjectedListeners` | e2e [12] (mock EIP-1193 provider: starts on the wrong chain → `wallet_switchEthereumChain`; tx sent through the provider; `accountsChanged` followed) | not tested with a real MetaMask extension (headless browser) |
| F10 | Wallet mode 2: local demo wallet (account switcher, friendly names) | Done | `wallet.js useLocalAccount`, `renderWalletWidget` | every e2e step | Alice … Judy |
| F11 | Balances, refresh after tx and by polling, pending/confirmed/failed states | Done | `app.js refreshAll` (1.5 s polling on new blocks), `chain.js sendTx`, `ui.js toast` | e2e (waits on confirmed toasts) | |
| F12 | Custom-error reverts decoded into human-readable messages | Done | `chain.js decodeError` + `FRIENDLY` map (all custom errors of all contracts + OZ errors) | e2e [5] “Order #10 is no longer open …” | |
| F13 | Dev tools on chain 31337 (evm_increaseTime + evm_mine); UI uses chain time | Done | `views/devtools.js`, `chain.js increaseTime/refreshClock` | e2e [11] | "+1 h/+1 day/+7 days/custom/jump to next deadline" |
| F14 | Clean, responsive design | Done | `styles.css` (light + dark themes) | `15_mobile_market.png` (no horizontal scroll, asserted), `14_dark_market.png` | |

## Deliverables

| Deliverable | Status | Notes |
|---|---|---|
| `README.md` (overview, architecture, design decisions, security, gas, run/test, demo script, limitations, results) | Done | |
| `CHECKLIST.md` | Done | this file |
| `run.sh` (fresh anvil on 8554, deploy, seed, config, serve 5554, Ctrl-C cleanup) | Done | `ANVIL_PORT`/`WEB_PORT`/`SEED` overridable |
| `contracts/` with `src/`, `test/`, `script/`; `Deploy.s.sol` usable on a public testnet | Done | documented in README §6; **not deployed publicly** (as instructed) |
| `frontend/` static SPA (vendored ethers v6, works offline) | Done | no CDN at runtime |
| `e2e/smoke_test.py` + `e2e/screenshots/` | Done | 41 checks, starts/stops a fresh `run.sh` itself |
| `forge test` / `forge coverage --report summary` results in README | Done | 180/180 passing; `src/` 100 % lines, statements, branches, functions |
