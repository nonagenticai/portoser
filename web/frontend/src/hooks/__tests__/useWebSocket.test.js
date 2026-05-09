import { describe, it, expect } from 'vitest'
import { __test__ } from '../useWebSocket.js'

const { nextDelay, INITIAL_RECONNECT_DELAY_MS, MAX_RECONNECT_DELAY_MS } = __test__

describe('nextDelay (exponential backoff with jitter)', () => {
  it('roughly doubles the input within ±25% jitter', () => {
    // Range check across 200 trials: doubled value is 2000ms,
    // jitter band is [1500, 2500], floored at INITIAL_RECONNECT_DELAY_MS.
    for (let i = 0; i < 200; i++) {
      const next = nextDelay(1000)
      expect(next).toBeGreaterThanOrEqual(INITIAL_RECONNECT_DELAY_MS)
      expect(next).toBeLessThanOrEqual(2500)
    }
  })

  it('caps at MAX_RECONNECT_DELAY_MS even with jitter on the upside', () => {
    // Doubled = 60s, capped to 30s before jitter, so jittered is in [22500, 37500].
    // The cap applies to the doubled value (pre-jitter), which is what the
    // recovering-server intent calls for.
    for (let i = 0; i < 200; i++) {
      const next = nextDelay(MAX_RECONNECT_DELAY_MS)
      // Upper bound: cap (30000) + 25% jitter = 37500
      expect(next).toBeLessThanOrEqual(MAX_RECONNECT_DELAY_MS * 1.25)
      expect(next).toBeGreaterThanOrEqual(INITIAL_RECONNECT_DELAY_MS)
    }
  })

  it('never returns below the initial delay floor', () => {
    // If the previous delay was very small and jitter pulls negative, we
    // should still wait at least INITIAL_RECONNECT_DELAY_MS to avoid a tight loop.
    for (let i = 0; i < 200; i++) {
      const next = nextDelay(100)
      expect(next).toBeGreaterThanOrEqual(INITIAL_RECONNECT_DELAY_MS)
    }
  })

  it('grows monotonically on average across iterations', () => {
    // Run a fresh "session" 50 times and verify the median delay at iter 5
    // is meaningfully larger than at iter 1. This is the property that
    // actually matters: long-lasting outages get longer waits.
    const samplesAt = (iters) => {
      const out = []
      for (let trial = 0; trial < 50; trial++) {
        let d = INITIAL_RECONNECT_DELAY_MS
        for (let i = 0; i < iters; i++) d = nextDelay(d)
        out.push(d)
      }
      out.sort((a, b) => a - b)
      return out[Math.floor(out.length / 2)]
    }

    const early = samplesAt(1)
    const late = samplesAt(5)
    expect(late).toBeGreaterThan(early * 4)
  })
})
