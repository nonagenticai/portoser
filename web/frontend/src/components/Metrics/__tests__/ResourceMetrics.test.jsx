import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import ResourceMetrics from '../ResourceMetrics'

describe('ResourceMetrics Component', () => {
  describe('Loading State', () => {
    it('shows loading skeleton when loading is true', () => {
      const { container } = render(<ResourceMetrics loading={true} />)
      expect(container.querySelector('.animate-pulse')).toBeInTheDocument()
    })

    it('shows loading skeleton when metrics is null', () => {
      const { container } = render(<ResourceMetrics metrics={null} />)
      expect(container.querySelector('.animate-pulse')).toBeInTheDocument()
    })

    it('shows loading skeleton when metrics is undefined', () => {
      const { container } = render(<ResourceMetrics metrics={undefined} />)
      expect(container.querySelector('.animate-pulse')).toBeInTheDocument()
    })
  })

  describe('Null/Undefined Metrics Handling', () => {
    it('handles undefined cpu_percent gracefully', () => {
      const metrics = {
        cpu_percent: undefined,
        memory_percent: 50,
        disk_percent: 30
      }
      render(<ResourceMetrics metrics={metrics} />)
      expect(screen.getByText('CPU')).toBeInTheDocument()
      expect(screen.getByText('0.0%')).toBeInTheDocument()
    })

    it('handles null memory_percent gracefully', () => {
      const metrics = {
        cpu_percent: 50,
        memory_percent: null,
        disk_percent: 30
      }
      render(<ResourceMetrics metrics={metrics} />)
      expect(screen.getByText('Memory')).toBeInTheDocument()
      expect(screen.getByText('0.0%')).toBeInTheDocument()
    })

    it('handles all metrics as undefined', () => {
      const metrics = {
        cpu_percent: undefined,
        memory_percent: undefined,
        disk_percent: undefined
      }
      render(<ResourceMetrics metrics={metrics} />)
      const percentages = screen.getAllByText('0.0%')
      expect(percentages).toHaveLength(3)
    })

    it('handles mix of valid and undefined metrics', () => {
      const metrics = {
        cpu_percent: 75.5,
        memory_percent: undefined,
        disk_percent: 45.3
      }
      render(<ResourceMetrics metrics={metrics} />)
      expect(screen.getByText('75.5%')).toBeInTheDocument()
      expect(screen.getByText('0.0%')).toBeInTheDocument()
      expect(screen.getByText('45.3%')).toBeInTheDocument()
    })
  })

  describe('Valid Metrics Display', () => {
    it('displays CPU metric correctly', () => {
      const metrics = {
        cpu_percent: 65.7,
        cpu_cores: 4,
        memory_percent: 50,
        disk_percent: 30
      }
      render(<ResourceMetrics metrics={metrics} />)
      expect(screen.getByText('CPU')).toBeInTheDocument()
      expect(screen.getByText('65.7%')).toBeInTheDocument()
      expect(screen.getByText('4 cores')).toBeInTheDocument()
    })

    it('displays Memory metric correctly', () => {
      const metrics = {
        cpu_percent: 50,
        memory_percent: 85.2,
        memory_used: 8589934592, // 8 GB in bytes
        memory_total: 17179869184, // 16 GB in bytes
        disk_percent: 30
      }
      render(<ResourceMetrics metrics={metrics} />)
      expect(screen.getByText('Memory')).toBeInTheDocument()
      expect(screen.getByText('85.2%')).toBeInTheDocument()
    })

    it('displays Disk metric correctly', () => {
      const metrics = {
        cpu_percent: 50,
        memory_percent: 50,
        disk_percent: 92.8,
        disk_used: 480000000000, // ~480 GB
        disk_total: 512000000000 // ~512 GB
      }
      render(<ResourceMetrics metrics={metrics} />)
      expect(screen.getByText('Disk')).toBeInTheDocument()
      expect(screen.getByText('92.8%')).toBeInTheDocument()
    })
  })

  describe('Color Coding', () => {
    it('applies green color for values < 70%', () => {
      const metrics = {
        cpu_percent: 50,
        memory_percent: 50,
        disk_percent: 50
      }
      const { container } = render(<ResourceMetrics metrics={metrics} />)
      const greenBars = container.querySelectorAll('.bg-green-500')
      expect(greenBars.length).toBeGreaterThan(0)
    })

    it('applies yellow color for values 70-89%', () => {
      const metrics = {
        cpu_percent: 75,
        memory_percent: 75,
        disk_percent: 75
      }
      const { container } = render(<ResourceMetrics metrics={metrics} />)
      const yellowBars = container.querySelectorAll('.bg-yellow-500')
      expect(yellowBars.length).toBeGreaterThan(0)
    })

    it('applies red color for values >= 90%', () => {
      const metrics = {
        cpu_percent: 95,
        memory_percent: 95,
        disk_percent: 95
      }
      const { container } = render(<ResourceMetrics metrics={metrics} />)
      const redBars = container.querySelectorAll('.bg-red-500')
      expect(redBars.length).toBeGreaterThan(0)
    })
  })

  describe('Progress Bar Width', () => {
    it('sets progress bar width to 0% for undefined values', () => {
      const metrics = {
        cpu_percent: undefined,
        memory_percent: undefined,
        disk_percent: undefined
      }
      const { container } = render(<ResourceMetrics metrics={metrics} />)
      const progressBars = container.querySelectorAll('[style*="width"]')
      progressBars.forEach(bar => {
        expect(bar.style.width).toBe('0%')
      })
    })

    it('sets progress bar width correctly for valid values', () => {
      const metrics = {
        cpu_percent: 75,
        memory_percent: 50,
        disk_percent: 90
      }
      const { container } = render(<ResourceMetrics metrics={metrics} />)
      const progressBars = container.querySelectorAll('[style*="width"]')
      expect(progressBars.length).toBeGreaterThan(0)
    })

    it('caps progress bar width at 100%', () => {
      const metrics = {
        cpu_percent: 150, // Over 100%
        memory_percent: 50,
        disk_percent: 50
      }
      const { container } = render(<ResourceMetrics metrics={metrics} />)
      const progressBars = container.querySelectorAll('[style*="width"]')
      // Find the bar that should be capped
      const cappedBar = Array.from(progressBars).find(bar => 
        bar.style.width === '100%'
      )
      expect(cappedBar).toBeTruthy()
    })
  })

  describe('Network Metrics', () => {
    it('displays network metrics when available', () => {
      const metrics = {
        cpu_percent: 50,
        memory_percent: 50,
        disk_percent: 50,
        network_rx: 1048576, // 1 MB/s
        network_tx: 524288   // 0.5 MB/s
      }
      render(<ResourceMetrics metrics={metrics} />)
      expect(screen.getByText('Network I/O')).toBeInTheDocument()
    })

    it('handles undefined network metrics', () => {
      const metrics = {
        cpu_percent: 50,
        memory_percent: 50,
        disk_percent: 50,
        network_rx: undefined,
        network_tx: undefined
      }
      render(<ResourceMetrics metrics={metrics} />)
      // Network should still appear if rx or tx is defined
      expect(screen.queryByText('Network I/O')).not.toBeInTheDocument()
    })

    it('handles null network metrics', () => {
      const metrics = {
        cpu_percent: 50,
        memory_percent: 50,
        disk_percent: 50,
        network_rx: null,
        network_tx: null
      }
      render(<ResourceMetrics metrics={metrics} />)
      expect(screen.queryByText('Network I/O')).not.toBeInTheDocument()
    })
  })

  describe('Compact Mode', () => {
    it('renders in compact mode', () => {
      const metrics = {
        cpu_percent: 50,
        memory_percent: 50,
        disk_percent: 50
      }
      const { container } = render(<ResourceMetrics metrics={metrics} compact={true} />)
      expect(container.querySelector('.space-y-3')).toBeInTheDocument()
    })

    it('hides header in compact mode', () => {
      const metrics = {
        cpu_percent: 50,
        memory_percent: 50,
        disk_percent: 50
      }
      render(<ResourceMetrics metrics={metrics} compact={true} />)
      expect(screen.queryByText('Resource Usage')).not.toBeInTheDocument()
    })
  })

  describe('Machine Level Display', () => {
    it('shows "Host Resource Usage" when machineLevel is true', () => {
      const metrics = {
        cpu_percent: 50,
        memory_percent: 50,
        disk_percent: 50
      }
      render(<ResourceMetrics metrics={metrics} machineLevel={true} />)
      expect(screen.getByText('Host Resource Usage')).toBeInTheDocument()
    })

    it('shows "Resource Usage" when machineLevel is false', () => {
      const metrics = {
        cpu_percent: 50,
        memory_percent: 50,
        disk_percent: 50
      }
      render(<ResourceMetrics metrics={metrics} machineLevel={false} />)
      expect(screen.getByText('Resource Usage')).toBeInTheDocument()
    })
  })

  describe('Refresh Callback', () => {
    it('calls onRefresh when refresh button is clicked', () => {
      const onRefresh = vi.fn()
      const metrics = {
        cpu_percent: 50,
        memory_percent: 50,
        disk_percent: 50
      }
      render(<ResourceMetrics metrics={metrics} onRefresh={onRefresh} />)
      
      const refreshButton = screen.getByTitle('Refresh metrics')
      refreshButton.click()
      
      expect(onRefresh).toHaveBeenCalledTimes(1)
    })

    it('does not show refresh button when onRefresh is null', () => {
      const metrics = {
        cpu_percent: 50,
        memory_percent: 50,
        disk_percent: 50
      }
      render(<ResourceMetrics metrics={metrics} onRefresh={null} />)
      expect(screen.queryByTitle('Refresh metrics')).not.toBeInTheDocument()
    })
  })

  describe('Edge Cases', () => {
    it('handles empty metrics object', () => {
      render(<ResourceMetrics metrics={{}} />)
      expect(screen.getByText('CPU')).toBeInTheDocument()
      expect(screen.getByText('Memory')).toBeInTheDocument()
      expect(screen.getByText('Disk')).toBeInTheDocument()
    })

    it('handles metrics with only some properties', () => {
      const metrics = {
        cpu_percent: 75.5
        // memory_percent and disk_percent missing
      }
      render(<ResourceMetrics metrics={metrics} />)
      expect(screen.getByText('75.5%')).toBeInTheDocument()
    })

    it('handles zero values correctly', () => {
      const metrics = {
        cpu_percent: 0,
        memory_percent: 0,
        disk_percent: 0
      }
      render(<ResourceMetrics metrics={metrics} />)
      const zeroPercentages = screen.getAllByText('0.0%')
      expect(zeroPercentages).toHaveLength(3)
    })

    it('handles 100% values correctly', () => {
      const metrics = {
        cpu_percent: 100,
        memory_percent: 100,
        disk_percent: 100
      }
      render(<ResourceMetrics metrics={metrics} />)
      const hundredPercentages = screen.getAllByText('100.0%')
      expect(hundredPercentages).toHaveLength(3)
    })
  })
})
