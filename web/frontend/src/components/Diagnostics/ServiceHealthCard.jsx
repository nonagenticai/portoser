import React, { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import {
  Activity,
  AlertCircle,
  CheckCircle,
  ChevronDown,
  ChevronUp,
  Stethoscope,
  Eye,
  TrendingUp,
  TrendingDown,
  Minus
} from 'lucide-react'
import clsx from 'clsx'
import { getServiceHealth } from '../../api/client'
import HealthIndicator from '../HealthIndicator'

function ServiceHealthCard({ service, machine, onDiagnose, onViewDetails }) {
  const [isExpanded, setIsExpanded] = useState(false)

  // Fetch health data
  const { data: healthData, isLoading } = useQuery({
    queryKey: ['service-health', service.name, machine?.name],
    queryFn: () => getServiceHealth(service.name),
    refetchInterval: 30000, // Refresh every 30 seconds
  })

  const getHealthScore = () => {
    if (!healthData || !healthData.health_score) return 0
    return healthData.health_score
  }

  const getHealthStatus = () => {
    const score = getHealthScore()
    if (score >= 80) return 'healthy'
    if (score >= 60) return 'degraded'
    return 'unhealthy'
  }

  const getHealthColor = (status) => {
    switch (status) {
      case 'healthy':
        return 'bg-green-100 border-green-300 text-green-800'
      case 'degraded':
        return 'bg-yellow-100 border-yellow-300 text-yellow-800'
      case 'unhealthy':
        return 'bg-red-100 border-red-300 text-red-800'
      default:
        return 'bg-gray-100 border-gray-300 text-gray-800'
    }
  }

  const getScoreColor = (score) => {
    if (score >= 80) return 'text-green-600'
    if (score >= 60) return 'text-yellow-600'
    return 'text-red-600'
  }

  const getTrendIcon = () => {
    if (!healthData?.trend) return <Minus className="w-4 h-4 text-gray-400" />

    if (healthData.trend === 'improving') {
      return <TrendingUp className="w-4 h-4 text-green-600" />
    } else if (healthData.trend === 'degrading') {
      return <TrendingDown className="w-4 h-4 text-red-600" />
    }
    return <Minus className="w-4 h-4 text-gray-400" />
  }

  const healthStatus = getHealthStatus()
  const healthScore = getHealthScore()
  const topProblems = healthData?.problems?.slice(0, 3) || []

  return (
    <div className={clsx(
      'border-2 rounded-lg p-4 transition-all duration-200 hover:shadow-lg',
      getHealthColor(healthStatus)
    )}>
      {/* Header */}
      <div className="flex items-start justify-between mb-3">
        <div className="flex-1 min-w-0">
          <h3 className="font-semibold text-gray-900 truncate">
            {service.name}
          </h3>
          <p className="text-sm text-gray-600 truncate">
            {machine?.name || service.machine_name || 'Unknown machine'}
          </p>
        </div>

        <div className="flex items-center space-x-2 ml-2">
          {getTrendIcon()}
          <HealthIndicator status={healthData?.status || 'unknown'} />
        </div>
      </div>

      {/* Health Score Circle */}
      <div className="flex items-center justify-center mb-4">
        <div className="relative w-32 h-32">
          <svg className="transform -rotate-90 w-32 h-32">
            <circle
              cx="64"
              cy="64"
              r="56"
              stroke="#e5e7eb"
              strokeWidth="12"
              fill="none"
            />
            <circle
              cx="64"
              cy="64"
              r="56"
              stroke="currentColor"
              strokeWidth="12"
              fill="none"
              strokeDasharray={`${2 * Math.PI * 56}`}
              strokeDashoffset={`${2 * Math.PI * 56 * (1 - healthScore / 100)}`}
              className={getScoreColor(healthScore)}
              strokeLinecap="round"
            />
          </svg>
          <div className="absolute inset-0 flex flex-col items-center justify-center">
            <span className={clsx('text-3xl font-bold', getScoreColor(healthScore))}>
              {healthScore}
            </span>
            <span className="text-xs text-gray-600">Health</span>
          </div>
        </div>
      </div>

      {/* Status Badge */}
      <div className="flex items-center justify-center mb-4">
        <span className={clsx(
          'px-3 py-1 rounded-full text-sm font-medium border',
          getHealthColor(healthStatus)
        )}>
          {healthStatus.toUpperCase()}
        </span>
      </div>

      {/* Top Problems (Mini List) */}
      {topProblems.length > 0 && (
        <div className="mb-4">
          <div className="flex items-center space-x-2 mb-2">
            <AlertCircle className="w-4 h-4 text-orange-600" />
            <h4 className="text-sm font-semibold text-gray-900">
              Top Issues ({topProblems.length})
            </h4>
          </div>
          <div className="space-y-1">
            {topProblems.map((problem, idx) => (
              <div
                key={idx}
                className="text-xs text-gray-700 bg-white bg-opacity-50 px-2 py-1 rounded border border-gray-200 truncate"
                title={problem.description}
              >
                <span className="font-medium">{problem.name}:</span> {problem.description}
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Quick Actions */}
      <div className="flex items-center space-x-2">
        <button
          onClick={() => onDiagnose(service, machine)}
          className="flex-1 flex items-center justify-center space-x-1 px-3 py-2 bg-blue-600 text-white text-sm font-medium rounded-lg hover:bg-blue-700 transition-colors"
        >
          <Stethoscope className="w-4 h-4" />
          <span>Diagnose</span>
        </button>

        <button
          onClick={() => onViewDetails(service, machine)}
          className="flex-1 flex items-center justify-center space-x-1 px-3 py-2 border-2 border-gray-600 text-gray-800 text-sm font-medium rounded-lg hover:bg-gray-700 hover:text-white transition-colors"
        >
          <Eye className="w-4 h-4" />
          <span>Details</span>
        </button>
      </div>

      {/* Expandable Details */}
      {healthData?.observations && healthData.observations.length > 0 && (
        <>
          <button
            onClick={() => setIsExpanded(!isExpanded)}
            className="w-full flex items-center justify-center space-x-1 mt-3 px-3 py-2 text-sm text-gray-700 hover:bg-white hover:bg-opacity-50 rounded-lg transition-colors"
          >
            <span>More Info</span>
            {isExpanded ? (
              <ChevronUp className="w-4 h-4" />
            ) : (
              <ChevronDown className="w-4 h-4" />
            )}
          </button>

          {isExpanded && (
            <div className="mt-3 pt-3 border-t border-gray-300 space-y-2">
              <h4 className="text-sm font-semibold text-gray-900 mb-2">
                Recent Observations
              </h4>
              {healthData.observations.slice(0, 5).map((obs, idx) => (
                <div
                  key={idx}
                  className="text-xs bg-white bg-opacity-70 p-2 rounded border border-gray-200"
                >
                  <div className="flex items-center space-x-2 mb-1">
                    {obs.type === 'success' && <CheckCircle className="w-3 h-3 text-green-600" />}
                    {obs.type === 'warning' && <AlertCircle className="w-3 h-3 text-yellow-600" />}
                    {obs.type === 'info' && <Activity className="w-3 h-3 text-blue-600" />}
                    <span className="font-medium text-gray-900">{obs.name}</span>
                  </div>
                  <p className="text-gray-700">{obs.message}</p>
                </div>
              ))}
            </div>
          )}
        </>
      )}

      {/* Loading State */}
      {isLoading && (
        <div className="absolute inset-0 bg-white bg-opacity-70 flex items-center justify-center rounded-lg">
          <div className="text-center">
            <Activity className="w-8 h-8 text-blue-600 animate-spin mx-auto mb-2" />
            <p className="text-sm text-gray-600">Loading health data...</p>
          </div>
        </div>
      )}
    </div>
  )
}

export default ServiceHealthCard
