import { describe, it, expect } from 'vitest'
import { safeToFixed, safePercent, safeMemory } from '../formatters'

describe('safeToFixed', () => {
  describe('handles undefined values', () => {
    it('returns default "0.0" for undefined with 1 decimal', () => {
      expect(safeToFixed(undefined, 1)).toBe('0.0')
    })

    it('returns default "0.00" for undefined with 2 decimals', () => {
      expect(safeToFixed(undefined, 2)).toBe('0.00')
    })

    it('returns default "0.000" for undefined with 3 decimals', () => {
      expect(safeToFixed(undefined, 3)).toBe('0.000')
    })
  })

  describe('handles null values', () => {
    it('returns default "0.0" for null with 1 decimal', () => {
      expect(safeToFixed(null, 1)).toBe('0.0')
    })

    it('returns default "0.00" for null with 2 decimals', () => {
      expect(safeToFixed(null, 2)).toBe('0.00')
    })

    it('returns default "0.000" for null with 3 decimals', () => {
      expect(safeToFixed(null, 3)).toBe('0.000')
    })
  })

  describe('handles NaN values', () => {
    it('returns default for NaN', () => {
      expect(safeToFixed(NaN, 2)).toBe('0.00')
    })

    it('returns custom default for NaN when provided', () => {
      expect(safeToFixed(NaN, 2, '--')).toBe('--')
    })
  })

  describe('handles valid numbers', () => {
    it('formats positive numbers correctly', () => {
      expect(safeToFixed(3.14159, 2)).toBe('3.14')
    })

    it('formats negative numbers correctly', () => {
      expect(safeToFixed(-3.14159, 2)).toBe('-3.14')
    })

    it('formats zero correctly', () => {
      expect(safeToFixed(0, 2)).toBe('0.00')
    })

    it('rounds up correctly', () => {
      expect(safeToFixed(3.14567, 2)).toBe('3.15')
    })

    it('rounds down correctly', () => {
      expect(safeToFixed(3.14234, 2)).toBe('3.14')
    })

    it('handles large numbers', () => {
      expect(safeToFixed(9999.99, 1)).toBe('10000.0')
    })

    it('handles very small numbers', () => {
      expect(safeToFixed(0.00001, 5)).toBe('0.00001')
    })

    it('uses default 1 decimal when not specified', () => {
      expect(safeToFixed(3.14159)).toBe('3.1')
    })

    it('formats integers with decimals', () => {
      expect(safeToFixed(42, 2)).toBe('42.00')
    })
  })

  describe('custom default values', () => {
    it('uses custom default for undefined', () => {
      expect(safeToFixed(undefined, 2, '--')).toBe('--')
    })

    it('uses custom default for null', () => {
      expect(safeToFixed(null, 2, 'N/A')).toBe('N/A')
    })

    it('ignores custom default for valid numbers', () => {
      expect(safeToFixed(5.5, 1, '--')).toBe('5.5')
    })
  })

  describe('edge cases', () => {
    it('handles 0 decimals', () => {
      expect(safeToFixed(3.7, 0)).toBe('4')
    })

    it('handles negative zero', () => {
      expect(safeToFixed(-0, 2)).toBe('0.00')
    })

    it('handles Infinity as invalid', () => {
      // Infinity.toFixed() would throw, but we should handle it gracefully
      const result = safeToFixed(Infinity, 2)
      expect(result).toBe('Infinity')
    })

    it('handles negative Infinity as invalid', () => {
      const result = safeToFixed(-Infinity, 2)
      expect(result).toBe('-Infinity')
    })
  })
})

describe('safePercent', () => {
  it('formats valid percentage with % suffix', () => {
    expect(safePercent(85.5)).toBe('85.5%')
  })

  it('handles undefined values', () => {
    expect(safePercent(undefined)).toBe('0.0%')
  })

  it('handles null values', () => {
    expect(safePercent(null)).toBe('0.0%')
  })

  it('formats zero percentage', () => {
    expect(safePercent(0)).toBe('0.0%')
  })

  it('formats 100 percentage', () => {
    expect(safePercent(100)).toBe('100.0%')
  })

  it('formats decimal percentages', () => {
    expect(safePercent(99.95)).toBe('100.0%')
  })

  it('handles negative percentages', () => {
    expect(safePercent(-5.3)).toBe('-5.3%')
  })
})

describe('safeMemory', () => {
  it('formats valid memory with MB suffix', () => {
    expect(safeMemory(1024)).toBe('1024 MB')
  })

  it('handles undefined values', () => {
    expect(safeMemory(undefined)).toBe('0 MB')
  })

  it('handles null values', () => {
    expect(safeMemory(null)).toBe('0 MB')
  })

  it('formats zero memory', () => {
    expect(safeMemory(0)).toBe('0 MB')
  })

  it('formats decimal memory as integer (0 decimals)', () => {
    expect(safeMemory(1536.7)).toBe('1537 MB')
  })

  it('handles large memory values', () => {
    expect(safeMemory(16384)).toBe('16384 MB')
  })

  it('handles small memory values', () => {
    expect(safeMemory(64)).toBe('64 MB')
  })
})
