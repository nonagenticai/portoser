import React from 'react'
import { Clock, TrendingUp, Activity, AlertCircle } from 'lucide-react'
import { safeToFixed } from '../../utils/formatters'
import clsx from 'clsx'

/**
 * UptimeStats Component
 * Display uptime statistics for a service
 *
 * Color-coded by availability:
 * - Green: >99.9% (excellent)
 * - Yellow: 95-99.9% (good)
 * - Red: <95% (poor)
 */
function UptimeStats({ uptime, loading = false }) {
  if (loading || !uptime) {
    return (
      <div className="animate-pulse space-y-4">
        <div className="h-32 bg-gray-200 rounded-lg"></div>
        <div className="grid grid-cols-2 gap-4">
          {[1, 2, 3, 4].map(i => (
            <div key={i} className="h-20 bg-gray-200 rounded-lg"></div>
          ))}
        </div>
      </div>
    )
  }

  const availability = uptime.availability_percent || 0
  const uptimeDuration = uptime.uptime_duration || 0
  const downtimeDuration = uptime.downtime_duration || 0
  const mtbf = uptime.mtbf || 0 // Mean Time Between Failures (hours)
  const mttr = uptime.mttr || 0 // Mean Time To Recovery (minutes)
  const failureCount = uptime.failure_count || 0

  // Get availability color class
  const getAvailabilityColor = () => {
    if (availability >= 99.9) return 'text-green-600'
    if (availability >= 95) return 'text-yellow-600'
    return 'text-red-600'
  }

  const getAvailabilityBgColor = () => {
    if (availability >= 99.9) return 'bg-green-50'
    if (availability >= 95) return 'bg-yellow-50'
    return 'bg-red-50'
  }

  const getAvailabilityRingColor = () => {
    if (availability >= 99.9) return 'stroke-green-500'
    if (availability >= 95) return 'stroke-yellow-500'
    return 'stroke-red-500'
  }

  const getSLAStatus = () => {
    if (availability >= 99.9) return { label: 'Excellent', color: 'text-green-600' }
    if (availability >= 95) return { label: 'Good', color: 'text-yellow-600' }
    return { label: 'Poor', color: 'text-red-600' }
  }

  const slaStatus = getSLAStatus()

  return (
    <div className="space-y-6">
      {/* Uptime Circle and Main Stats */}
      <div className={clsx('rounded-lg p-6', getAvailabilityBgColor())}>
        <div className="flex items-center justify-between">
          {/* Circular Progress */}
          <div className="flex items-center space-x-6">
            <div className="relative">
              <svg className="w-32 h-32 transform -rotate-90">
                {/* Background circle */}
                <circle
                  cx="64"
                  cy="64"
                  r="56"
                  fill="none"
                  stroke="#e5e7eb"
                  strokeWidth="8"
                />
                {/* Progress circle */}
                <circle
                  cx="64"
                  cy="64"
                  r="56"
                  fill="none"
                  className={getAvailabilityRingColor()}
                  strokeWidth="8"
                  strokeLinecap="round"
                  strokeDasharray={`${2 * Math.PI * 56}`}
                  strokeDashoffset={`${2 * Math.PI * 56 * (1 - availability / 100)}`}
                  style={{ transition: 'stroke-dashoffset 0.5s ease' }}
                />
              </svg>
              {/* Center text */}
              <div className="absolute inset-0 flex items-center justify-center flex-col">
                <span className={clsx('text-3xl font-bold', getAvailabilityColor())}>
                  {safeToFixed(availability, 2)}%
                </span>
                <span className="text-xs text-gray-600">Uptime</span>
              </div>
            </div>

            {/* Duration Stats */}
            <div className="space-y-3">
              <div>
                <div className="flex items-center space-x-2 mb-1">
                  <Activity className="w-4 h-4 text-green-600" />
                  <span className="text-sm font-medium text-gray-700">Uptime Duration</span>
                </div>
                <div className="text-2xl font-bold text-gray-900">
                  {formatDuration(uptimeDuration)}
                </div>
              </div>

              {downtimeDuration > 0 && (
                <div>
                  <div className="flex items-center space-x-2 mb-1">
                    <AlertCircle className="w-4 h-4 text-red-600" />
                    <span className="text-sm font-medium text-gray-700">Downtime Duration</span>
                  </div>
                  <div className="text-xl font-bold text-red-600">
                    {formatDuration(downtimeDuration)}
                  </div>
                </div>
              )}
            </div>
          </div>

          {/* SLA Status Badge */}
          <div className={clsx('px-6 py-4 rounded-lg border-2', {
            'bg-green-50 border-green-200': availability >= 99.9,
            'bg-yellow-50 border-yellow-200': availability >= 95 && availability < 99.9,
            'bg-red-50 border-red-200': availability < 95
          })}>
            <div className="text-sm text-gray-600 mb-1">SLA Status</div>
            <div className={clsx('text-2xl font-bold', slaStatus.color)}>
              {slaStatus.label}
            </div>
          </div>
        </div>
      </div>

      {/* Additional Metrics Grid */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        {/* MTBF */}
        <MetricCard
          icon={Clock}
          label="MTBF"
          value={mtbf > 0 ? `${safeToFixed(mtbf, 1)} hrs` : 'N/A'}
          description="Mean Time Between Failures"
          color="blue"
        />

        {/* MTTR */}
        <MetricCard
          icon={TrendingUp}
          label="MTTR"
          value={mttr > 0 ? `${safeToFixed(mttr, 1)} min` : 'N/A'}
          description="Mean Time To Recovery"
          color="green"
        />

        {/* Failure Count */}
        <MetricCard
          icon={AlertCircle}
          label="Failures"
          value={failureCount.toString()}
          description="Total failure count"
          color={failureCount === 0 ? 'green' : failureCount < 5 ? 'yellow' : 'red'}
        />
      </div>

      {/* SLA Targets Reference */}
      <div className="bg-gray-50 rounded-lg p-4">
        <h4 className="text-sm font-semibold text-gray-700 mb-3">SLA Targets</h4>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
          <SLATarget
            percentage="99.9%"
            label="Three nines"
            downtime="~8.7h/year"
            met={availability >= 99.9}
          />
          <SLATarget
            percentage="99.95%"
            label="High availability"
            downtime="~4.4h/year"
            met={availability >= 99.95}
          />
          <SLATarget
            percentage="99.99%"
            label="Four nines"
            downtime="~52min/year"
            met={availability >= 99.99}
          />
        </div>
      </div>
    </div>
  )
}

/**
 * MetricCard - Individual metric display
 */
function MetricCard({ icon: Icon, label, value, description, color = 'gray' }) {
  const colorClasses = {
    blue: 'bg-blue-50 text-blue-700',
    green: 'bg-green-50 text-green-700',
    yellow: 'bg-yellow-50 text-yellow-700',
    red: 'bg-red-50 text-red-700',
    gray: 'bg-gray-50 text-gray-700'
  }

  return (
    <div className="bg-white border border-gray-200 rounded-lg p-4">
      <div className="flex items-center space-x-3 mb-2">
        <div className={clsx('p-2 rounded-lg', colorClasses[color])}>
          <Icon className="w-5 h-5" />
        </div>
        <div>
          <div className="text-sm font-medium text-gray-600">{label}</div>
          <div className="text-lg font-bold text-gray-900">{value}</div>
        </div>
      </div>
      <div className="text-xs text-gray-500">{description}</div>
    </div>
  )
}

/**
 * SLATarget - Display SLA target with met/not met status
 */
function SLATarget({ percentage, label, downtime, met }) {
  return (
    <div className={clsx('p-3 rounded-lg border', {
      'bg-green-50 border-green-200': met,
      'bg-gray-50 border-gray-200': !met
    })}>
      <div className="flex items-center justify-between mb-1">
        <span className="text-sm font-bold text-gray-900">{percentage}</span>
        {met && (
          <div className="w-2 h-2 bg-green-500 rounded-full"></div>
        )}
      </div>
      <div className="text-xs text-gray-600">{label}</div>
      <div className="text-xs text-gray-500 mt-1">{downtime}</div>
    </div>
  )
}

/**
 * Format duration in seconds to human-readable format
 */
function formatDuration(seconds) {
  const days = Math.floor(seconds / 86400)
  const hours = Math.floor((seconds % 86400) / 3600)
  const minutes = Math.floor((seconds % 3600) / 60)

  const parts = []
  if (days > 0) parts.push(`${days}d`)
  if (hours > 0) parts.push(`${hours}h`)
  if (minutes > 0 || parts.length === 0) parts.push(`${minutes}m`)

  return parts.join(' ')
}

export default UptimeStats
