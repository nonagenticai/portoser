import React from 'react'
import { CheckCircle, XCircle, AlertCircle } from 'lucide-react'
import { safeToFixed } from '../../utils/formatters'
import clsx from 'clsx'

/**
 * SLAIndicator Component
 * Shows if service meets SLA (Service Level Agreement)
 */
function SLAIndicator({ availability, slaTarget = 99.9, compact = false }) {
  const isMet = availability >= slaTarget
  const difference = availability - slaTarget

  // Get status based on how close to target
  const getStatus = () => {
    if (availability >= slaTarget) {
      return 'met'
    } else if (availability >= slaTarget - 1) {
      return 'warning'
    } else {
      return 'missed'
    }
  }

  const status = getStatus()

  // Status configurations
  const statusConfig = {
    met: {
      icon: CheckCircle,
      label: 'SLA Met',
      color: 'text-green-600',
      bg: 'bg-green-50',
      border: 'border-green-200'
    },
    warning: {
      icon: AlertCircle,
      label: 'SLA Warning',
      color: 'text-yellow-600',
      bg: 'bg-yellow-50',
      border: 'border-yellow-200'
    },
    missed: {
      icon: XCircle,
      label: 'SLA Missed',
      color: 'text-red-600',
      bg: 'bg-red-50',
      border: 'border-red-200'
    }
  }

  const config = statusConfig[status]
  const Icon = config.icon

  if (compact) {
    return (
      <div className={clsx('inline-flex items-center space-x-1.5 px-2 py-1 rounded-full border', config.bg, config.border)}>
        <Icon className={clsx('w-3 h-3', config.color)} />
        <span className={clsx('text-xs font-semibold', config.color)}>
          {safeToFixed(availability, 2)}%
        </span>
      </div>
    )
  }

  return (
    <div className={clsx('rounded-lg border p-4', config.bg, config.border)}>
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center space-x-2">
          <Icon className={clsx('w-5 h-5', config.color)} />
          <h4 className={clsx('font-semibold', config.color)}>{config.label}</h4>
        </div>
        <span className={clsx('text-2xl font-bold', config.color)}>
          {safeToFixed(availability, 2)}%
        </span>
      </div>

      <div className="space-y-2">
        <div className="flex items-center justify-between text-sm">
          <span className="text-gray-600">SLA Target:</span>
          <span className="font-semibold text-gray-900">{slaTarget}%</span>
        </div>

        <div className="flex items-center justify-between text-sm">
          <span className="text-gray-600">Difference:</span>
          <span className={clsx('font-semibold', isMet ? 'text-green-600' : 'text-red-600')}>
            {difference >= 0 ? '+' : ''}{safeToFixed(difference, 3)}%
          </span>
        </div>

        {/* Progress bar */}
        <div className="mt-3">
          <div className="w-full h-2 bg-gray-200 rounded-full overflow-hidden">
            <div
              className={clsx('h-full transition-all', {
                'bg-green-500': isMet,
                'bg-yellow-500': status === 'warning',
                'bg-red-500': status === 'missed'
              })}
              style={{ width: `${Math.min(availability, 100)}%` }}
            />
          </div>
          <div className="flex justify-between text-xs text-gray-500 mt-1">
            <span>0%</span>
            <span className="font-medium">{slaTarget}%</span>
            <span>100%</span>
          </div>
        </div>

        {/* Common SLA targets reference */}
        <div className="mt-4 pt-3 border-t border-gray-200">
          <div className="text-xs font-medium text-gray-700 mb-2">Common SLA Targets</div>
          <div className="space-y-1.5">
            <SLATargetLine
              percentage={99.9}
              label="Three nines"
              downtime="~8.7h/year"
              current={availability}
            />
            <SLATargetLine
              percentage={99.95}
              label="High availability"
              downtime="~4.4h/year"
              current={availability}
            />
            <SLATargetLine
              percentage={99.99}
              label="Four nines"
              downtime="~52min/year"
              current={availability}
            />
          </div>
        </div>
      </div>
    </div>
  )
}

/**
 * SLATargetLine - Shows a single SLA target with achievement status
 */
function SLATargetLine({ percentage, label, downtime, current }) {
  const isAchieved = current >= percentage

  return (
    <div className={clsx('flex items-center justify-between text-xs p-2 rounded', {
      'bg-green-50': isAchieved,
      'bg-gray-50': !isAchieved
    })}>
      <div className="flex items-center space-x-2">
        <div className={clsx('w-1.5 h-1.5 rounded-full', {
          'bg-green-500': isAchieved,
          'bg-gray-300': !isAchieved
        })} />
        <span className={clsx('font-medium', {
          'text-gray-900': isAchieved,
          'text-gray-600': !isAchieved
        })}>
          {percentage}%
        </span>
        <span className="text-gray-500">- {label}</span>
      </div>
      <span className="text-gray-500">{downtime}</span>
    </div>
  )
}

export default SLAIndicator
