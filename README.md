# Fixed/Leverage Yield Trading hook for Uniswap v4

The yield (or APY) generated from fees while LPing into pools is varying a lot. 
It can be 20-30% one day, 0.1% the other. So there is some opportunity to gamble like a degen :D

On the other hand, users might be more attracted to LP if they have a fixed yield, so that they know what to expect. (Even if it means that the yield will be lower)

# Logic behind the hook

Instead of all liquidity providers sharing the same variable yield, this hook splits LPs into two distinct groups—those who want a fixed, predictable return (aToken holders) and those willing to take on a leveraged, higher-risk position (xToken holders).

There are two tokens, aToken and xToken. aToken will have fixed yield. xToken holders will be the ones paying that yield. What's left is all theirs. 

## How It Works:

- **Two-Tiered Liquidity Structure:**  
  When liquidity is added to the pool, providers can choose one of two roles:  
  - **aToken Providers:** These LPs receive a guaranteed, time-based interest (APY) on their deposited principal, regardless of how much the underlying Uniswap position actually earns.  
  - **xToken Providers:** These LPs take the opposite side. They pay the promised APY to the aToken side and, in exchange, gain access to any upside if the LP position outperforms that fixed rate. Conversely, they also bear the downside risk if the position underperforms.

- **Dynamic Fee Allocation:**  
  The pool accumulates fees from trading activity, just like a normal Uniswap liquidity position. At regular intervals, the hook calculates how much interest is owed to aToken holders.  
  - If enough fees have accrued, the interest is paid entirely from these fees. Any remaining surplus fees increase the xToken principal, acting like leveraged gains.  
  - If fees are insufficient, xToken holders must cover the shortfall out of their own principal, effectively transferring value from the leveraged side to maintain the aToken’s guaranteed interest.

## Key Benefits:

- **Predictability for aToken Holders:**  
  By fixing the APY, one class of investors enjoys a stable, predictable return, insulating them from volatility and uncertainty.

- **Leverage for xToken Holders:**  
  The other class seeks potentially higher returns, at the cost of taking on more risk. They gain if the LP position earns more than the fixed rate, but pay out if it earns less.

- **Flexible Fee Distribution:**  
  This structure adapts to changing market conditions. High fee environments reward the leveraged side, while low fee environments protect the fixed-rate side at the expense of leveraged investors.

## **Use Cases:**

- **Yield-Seeking LPs:** Retail or conservative investors may prefer the aToken side to receive a stable, bond-like return.  
- **Speculators and Skilled Traders:** More sophisticated participants looking for leveraged exposure to Uniswap LP yields can opt into the xToken side, aiming to outperform the fixed APY and capture extra yield.

In essence, the `FixedYieldLeveragePool` hook transforms standard LP shares into a dual-class system, balancing guaranteed returns against leveraged speculation, all built on top of the Uniswap v4 protocol.

## Disclaimer: 
Didn't write the code from scratch. To make the swaps/add liquidity work, I checked these repos:
- https://github.com/synote/fixed-weights-pool
- https://github.com/haardikk21/csmm-noop-hook