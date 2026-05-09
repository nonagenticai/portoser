import React from 'react'
import PropTypes from 'prop-types'
import { Cpu, MemoryStick, HardDrive, Network, RefreshCw } from 'lucide-react'
import { safeToFixed } from '../../utils/formatters'
import clsx from 'clsx'

/**
 * ResourceMetrics Component
 * Displays current resource usage for a service or machine with color-coded progress bars
 *
 * Supports both service-level and machine-level (host) metrics display.
 * For machine-level display, set machineLevel prop to true.
 *
 * Color coding:
 * - Green: < 70%
 * - Yellow: 70-90%
 * - Red: > 90%
 *
 * Props:
 * - metrics: Object containing metric data (cpu_percent, memory_percent, disk_percent, etc.)
 * - loading: Boolean indicating if metrics are loading
 * - compact: Boolean for compact display mode
 * - machineLevel: Boolean indicating if displaying machine/host-level metrics
 * - onRefresh: Callback function for refresh button
 */
function ResourceMetrics({
  metrics,
  loading = false,
  compact = false,
  machineLevel = false,
  onRefresh
}) {
  if (loading || !metrics) {
    return (
      <div className={clsx('animate-pulse', compact ? 'space-y-2' : 'space-y-4')}>
        {[1, 2, 3].map(i => (
          <div key={i} className="space-y-2">
            <div className="h-4 bg-gray-200 rounded w-24"></div>
            <div className="h-2 bg-gray-200 rounded"></div>
          </div>
        ))}
      </div>
    )
  }

  const getColorClass = (percentage) => {
    if (percentage >= 90) return 'bg-red-500'
    if (percentage >= 70) return 'bg-yellow-500'
    return 'bg-green-500'
  }

  const getBackgroundColorClass = (percentage) => {
    if (percentage >= 90) return 'bg-red-50'
    if (percentage >= 70) return 'bg-yellow-50'
    return 'bg-green-50'
  }

  const getTextColorClass = (percentage) => {
    if (percentage >= 90) return 'text-red-700'
    if (percentage >= 70) return 'text-yellow-700'
    return 'text-green-700'
  }

  const resourceItems = [
    {
      label: 'CPU',
      icon: Cpu,
      value: metrics.cpu_percent,
      unit: '%',
      description: `${metrics.cpu_cores || 'N/A'} cores`
    },
    {
      label: 'Memory',
      icon: MemoryStick,
      value: metrics.memory_percent,
      unit: '%',
      description: `${formatBytes(metrics.memory_used || 0)} / ${formatBytes(metrics.memory_total || 0)}`
    },
    {
      label: 'Disk',
      icon: HardDrive,
      value: metrics.disk_percent,
      unit: '%',
      description: `${formatBytes(metrics.disk_used || 0)} / ${formatBytes(metrics.disk_total || 0)}`
    }
  ]

  // Add network if at least one of rx/tx is a real number (not null/undefined).
  if (metrics.network_rx != null || metrics.network_tx != null) {
    resourceItems.push({
      label: 'Network I/O',
      icon: Network,
      value: null, // No percentage for network
      unit: '',
      description: `RX: ${formatBytes(metrics.network_rx || 0)}/s | TX: ${formatBytes(metrics.network_tx || 0)}/s`
    })
  }

  return (
    <div className={clsx('space-y-4', compact && 'space-y-3')}>
      {/* Header */}
      {!compact && (
        <div className="flex items-center justify-between">
          <h3 className="text-lg font-semibold text-gray-900">
            {machineLevel ? 'Host Resource Usage' : 'Resource Usage'}
          </h3>
          {onRefresh && (
            <button
              onClick={onRefresh}
              className="p-1.5 hover:bg-gray-100 rounded-lg transition-colors"
              title="Refresh metrics"
            >
              <RefreshCw className="w-4 h-4 text-gray-600" />
            </button>
          )}
        </div>
      )}

      {/* Resource Items */}
      <div className={clsx('space-y-3', compact && 'space-y-2')}>
        {resourceItems.map((item) => (
          <div key={item.label}>
            <div className="flex items-center justify-between mb-1.5">
              <div className="flex items-center space-x-2">
                <item.icon className={clsx(
                  'flex-shrink-0',
                  compact ? 'w-3.5 h-3.5' : 'w-4 h-4',
                  item.value !== null ? getTextColorClass(item.value) : 'text-gray-600'
                )} />
                <span className={clsx(
                  'font-medium',
                  compact ? 'text-xs' : 'text-sm',
                  'text-gray-700'
                )}>
                  {item.label}
                </span>
              </div>
              <div className="flex items-center space-x-2">
                {item.unit !== '' && (
                  <span className={clsx(
                    'font-semibold',
                    compact ? 'text-xs' : 'text-sm',
                    getTextColorClass(item.value ?? 0)
                  )}>
                    {safeToFixed(item.value, 1)}{item.unit}
                  </span>
                )}
                {!compact && (
                  <span className="text-xs text-gray-500">
                    {item.description}
                  </span>
                )}
              </div>
            </div>

            {/* Progress Bar */}
            {item.value !== null && (
              <div className={clsx(
                'w-full rounded-full overflow-hidden',
                compact ? 'h-1.5' : 'h-2',
                getBackgroundColorClass(item.value)
              )}>
                <div
                  className={clsx(
                    'h-full transition-all duration-300 ease-out',
                    getColorClass(item.value)
                  )}
                  style={{ width: `${Math.min(item.value, 100)}%` }}
                />
              </div>
            )}

            {/* Network description in compact mode */}
            {compact && item.label === 'Network I/O' && (
              <div className="text-xs text-gray-500 mt-1">
                {item.description}
              </div>
            )}
          </div>
        ))}
      </div>

      {/* Last Updated */}
      {!compact && metrics.timestamp && (
        <div className="text-xs text-gray-500 text-right">
          Last updated: {new Date(metrics.timestamp).toLocaleTimeString()}
        </div>
      )}
    </div>
  )
}

/**
 * Format bytes to human-readable format
 */
function formatBytes(bytes, decimals = 1) {
  if (bytes === 0) return '0 B'

  const k = 1024
  const dm = decimals < 0 ? 0 : decimals
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB']

  const i = Math.floor(Math.log(bytes) / Math.log(k))

  return parseFloat(safeToFixed(bytes / Math.pow(k, i), dm)) + ' ' + sizes[i]
}

/**
 * PropTypes validation
 * Defines expected prop types for ResourceMetrics component
 */
ResourceMetrics.propTypes = {
  // Metrics object containing resource usage data
  metrics: PropTypes.shape({
    // CPU metrics
    cpu_percent: PropTypes.number,
    cpu_cores: PropTypes.oneOfType([PropTypes.number, PropTypes.string]),

    // Memory metrics
    memory_percent: PropTypes.number,
    memory_used: PropTypes.number,
    memory_total: PropTypes.number,

    // Disk metrics
    disk_percent: PropTypes.number,
    disk_used: PropTypes.number,
    disk_total: PropTypes.number,

    // Network metrics (optional)
    network_rx: PropTypes.number,
    network_tx: PropTypes.number,

    // Timestamp for last update
    timestamp: PropTypes.oneOfType([PropTypes.string, PropTypes.number])
  }),

  // Loading state indicator
  loading: PropTypes.bool,

  // Compact display mode
  compact: PropTypes.bool,

  // Machine-level (host) metrics indicator
  machineLevel: PropTypes.bool,

  // Refresh callback function
  onRefresh: PropTypes.func
}

/**
 * Default props
 */
ResourceMetrics.defaultProps = {
  metrics: null,
  loading: false,
  compact: false,
  machineLevel: false,
  onRefresh: null
}

export default ResourceMetrics
