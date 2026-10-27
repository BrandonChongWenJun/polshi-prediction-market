"""Narration for the demo video: one entry per caption, spoken in order by record.py.

`text` is shown as the caption; SPOKEN rewrites it into what the voice should say (acronyms, code names).
"""

import re

SECTIONS = [
    ("Architecture", [
        ("a01", "WiseCrowd is a decentralized prediction market. Anyone can open a market on a future event, trade outcome shares whose prices are the crowd's probabilities, and get paid once the result is settled."),
        ("a02", "The front end is a static web app in plain JavaScript and ethers v6. It connects through a built-in demo wallet, or through MetaMask."),
        ("a03", "On chain, three Solidity contracts do the work, built with Foundry and OpenZeppelin."),
        ("a04", "PredictionMarket holds every market in one contract. It mints outcome shares as ERC-1155 tokens, prices them with an automated market maker, and handles liquidity, fees, resolution and payouts."),
        ("a05", "OrderBook is bonus one: a peer-to-peer order book where every order is escrowed on chain."),
        ("a06", "ReputationOracle is bonus three: registered reporters settle a market by a reputation-weighted vote."),
        ("a07", "And for bonus two, markets can use USDT with 6 decimals, DAI, or wrapped ether as collateral."),
        ("a08", "Two design choices keep the market safe. Shares are only created in complete sets: one unit of collateral mints one share of every outcome."),
        ("a09", "So every share is fully backed, and the contract can always pay every winner. Invariant tests check this after thousands of random actions."),
        ("a10", "Prices come from a Gnosis-style fixed-product market maker. Buying an outcome makes it scarcer in the pool, so its price rises, and the prices always add up to 100%."),
        ("a11", "Each market is created, traded until it closes, and resolved. Then winners redeem one unit of collateral per winning share."),
        ("a11b", "AMM trading stops at the close time, set before the event. The pool is the liquidity providers' money, and they shouldn't be forced to trade with someone who already knows the result."),
        ("a11c", "Peer-to-peer orders and minting complete sets stay open until resolution, because they put no one at risk who didn't agree to it. So holders can still sell while they wait for the result."),
        ("a12", "It's resolved by a named arbitrator or by a reporter vote. If nobody reports within seven days, anyone can declare it invalid, which pays 1/N per share."),
    ]),
    ("Local deployment", [
        ("b01", "Now the hands-on demo, deployed on a local Anvil blockchain. One command, run.sh, starts the chain, compiles the contracts, and deploys them with three collateral tokens."),
        ("b02", "It then seeds ten days of history, with nine markets and 265 transactions, and serves the web app."),
    ]),
    ("Market list and demo accounts", [
        ("c01", "Here's the market list: nine markets in three currencies, each showing live odds and its stage."),
        ("c02", "Four are trading. The others are waiting for an arbitrator, timed out, in a reporter vote, or already resolved."),
        ("c03", "The status bar shows the local chain and its clock. Every deadline uses the latest block's time."),
        ("c04", "The account menu switches between ten funded demo accounts. I'll start as Bob, a trader."),
    ]),
    ("Buying and selling shares", [
        ("d01", "Let's open the Bitcoin market. Its question, collateral, arbitrator and deadlines are fixed when it's created."),
        ("d02", "The probability chart is rebuilt from on-chain events. I can hover over any point, or switch to a table."),
        ("d03", "To buy, I pick Yes and enter 250 USDT."),
        ("d04", "Before anything is sent, the quote shows my shares, the average price, the price impact, the new probability, the fee, and my payout if Yes wins."),
        ("d05", "A 1% slippage limit protects me if the price moves before my trade is mined."),
        ("d06", "I buy. The transaction goes from pending to confirmed, the Yes odds rise, and my position appears."),
        ("d07", "Selling is the reverse. I sell exactly 100 shares and get the quoted amount back."),
    ]),
    ("Peer-to-peer order book (bonus 1)", [
        ("e01", "The order book tab is the peer-to-peer market. I post a sell order for 50 Yes shares at 0.45 USDT each."),
        ("e02", "The contract takes the 50 shares into escrow, so the order can always be filled."),
        ("e03", "Now I switch to Frank, take that order, and buy 20 of its shares. It's a partial fill, so 30 shares stay on offer."),
        ("e04", "Back as Bob, my order shows as partially filled. I cancel the rest, and the 30 unsold shares come back to me."),
        ("e05", "Orders stay fillable after AMM trading closes, right up until the market is resolved."),
    ]),
    ("Liquidity and complete sets", [
        ("f01", "In Liquidity and sets, anyone can provide liquidity. I add 200 USDT and get LP shares, which earn part of the 2% trading fee."),
        ("f02", "Liquidity can always be withdrawn, even if the contract is paused. I remove all of it."),
        ("f03", "I can also mint complete sets: 5 USDT becomes 5 Yes and 5 No shares."),
        ("f04", "Merging a full set turns it back into 5 USDT at any time."),
    ]),
    ("Resolution by the arbitrator", [
        ("g01", "Now resolution. The SC4053 quiz market is past its resolution time and waiting for its arbitrator, Dave."),
        ("g02", "Only Dave can report, and only after that time. As Dave, I select Yes and submit the report."),
        ("g03", "The market resolves to Yes. Back as Bob, I redeem, and each winning share pays 1 USDT."),
    ]),
    ("Reputation-weighted vote (bonus 3)", [
        ("h01", "The rainfall market is settled by a reputation-weighted vote. Eve has already voted."),
        ("h02", "Each vote is weighted by the reporter's reputation, and a result needs votes worth at least half of all reputation."),
        ("h03", "I switch to Frank, one of the registered reporters, and he votes Yes."),
        ("h04", "Then Heidi votes No. She has only 80 reputation, after voting against the consensus once before."),
        ("h05", "Voting lasts one day, so I use the dev tools to move the local chain forward a day, and then finalize the vote."),
        ("h06", "Yes is reported to the market."),
        ("h07", "On the Reporters page, Frank gained 10 reputation for agreeing, and Heidi lost 20%."),
        ("h08", "Only the admin can register reporters. As Alice, I register Judy, who starts with 100 reputation."),
    ]),
    ("Timeout and invalid markets", [
        ("i01", "The L1 gas market's arbitrator, Ivan, never reported. Seven days have passed, so anyone can resolve it as invalid."),
        ("i02", "Invalid markets pay 1/N per share, so no money stays locked. Bob redeems his refund."),
    ]),
    ("New user creates a WETH market (bonus 2)", [
        ("j01", "Finally, a brand-new user, Judy. On the Wallet page, she wraps 2 ether into WETH."),
        ("j02", "Then she creates a market. She types a question, adds a third outcome, and sets her own starting odds of 50, 30 and 20 percent."),
        ("j03", "She picks WETH as the collateral, adds the starting liquidity, and chooses the reporter vote to settle it."),
        ("j04", "Creating it approves exactly that amount, then creates the market. It opens at her odds, with Judy as its first liquidity provider."),
    ]),
    ("Portfolio", [
        ("k01", "The Portfolio page collects a user's positions, liquidity, open orders and winnings. Alice, a liquidity provider, claims her trading fees."),
    ]),
    ("Tests and summary", [
        ("l01", "Behind the demo, all 180 Foundry tests pass, including fuzz and invariant tests that show the market stays solvent."),
        ("l02", "That's WiseCrowd: markets, trading, liquidity, peer-to-peer orders, and resolution by arbitrator, vote or timeout. Thanks for watching."),
    ]),
]

SPOKEN = [
    (r"\bPredictionMarket\b", "Prediction Market"),
    (r"\bOrderBook\b", "Order Book"),
    (r"\bReputationOracle\b", "Reputation Oracle"),
    (r"\bOpenZeppelin\b", "Open Zeppelin"),
    (r"\bERC-1155\b", "E R C eleven fifty-five"),
    (r"\bethers v6\b", "ethers version six"),
    (r"\brun\.sh\b", "run dot S H"),
    (r"\bSC4053\b", "S C forty fifty-three"),
    (r"\bUSDT\b", "U S D T"),
    (r"\bAMM\b", "A M M"),
    (r"\bL1\b", "L one"),
    (r"\bWETH\b", "weth"),
    (r"1/N", "one over N"),
]

LINES = {uid: text for _, items in SECTIONS for uid, text in items}
SECTION_OF = {uid: name for name, items in SECTIONS for uid, _ in items}


def spoken(text: str) -> str:
    for pattern, repl in SPOKEN:
        text = re.sub(pattern, repl, text)
    return text
