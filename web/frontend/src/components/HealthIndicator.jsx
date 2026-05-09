import React from 'react'
import Tooltip from './Tooltip'
import clsx from 'clsx'

const HEALTH_STATUS = {
  healthy: {
    color: 'bg-green-500',
    label: 'Healthy',
    description: 'Service is running and responding to health checks',
  },
  unhealthy: {
    color: 'bg-red-500',
    label: 'Issue Detected',
    description: 'Service is not responding or health check failed',
  },
  stopped: {
    color: 'bg-yellow-500',
    label: 'Not Running',
    description: 'Service is not currently running',
  },
  unknown: {
    color: 'bg-gray-400',
    label: 'Unknown',
    description: 'Health status could not be determined',
  },
}

function HealthIndicator({ status = 'unknown', className = '' }) {
  const config = HEALTH_STATUS[status] || HEALTH_STATUS.unknown

  return (
    <Tooltip content={`${config.label}: ${config.description}`}>
      <div className={clsx('relative', className)}>
        <div
          className={clsx(
            'w-2.5 h-2.5 rounded-full',
            config.color,
            status === 'healthy' && 'animate-pulse'
          )}
        />
        {/* Outer ring for emphasis */}
        <div
          className={clsx(
            'absolute inset-0 w-2.5 h-2.5 rounded-full opacity-20',
            config.color
          )}
        />
      </div>
    </Tooltip>
  )
}

export default HealthIndicator
