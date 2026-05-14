import React, { useState } from 'react'
import { AlertTriangle, AlertCircle, Info, ChevronDown, ChevronRight, Wrench, SkipForward, Hand } from 'lucide-react'
import clsx from 'clsx'

const SEVERITY_CONFIG = {
  high: {
    icon: AlertCircle,
    color: 'text-red-600',
    bg: 'bg-red-50',
    border: 'border-red-300',
    label: 'High',
    badgeBg: 'bg-red-100',
    badgeText: 'text-red-700',
  },
  medium: {
    icon: AlertTriangle,
    color: 'text-yellow-600',
    bg: 'bg-yellow-50',
    border: 'border-yellow-300',
    label: 'Medium',
    badgeBg: 'bg-yellow-100',
    badgeText: 'text-yellow-700',
  },
  low: {
    icon: Info,
    color: 'text-blue-600',
    bg: 'bg-blue-50',
    border: 'border-blue-300',
    label: 'Low',
    badgeBg: 'bg-blue-100',
    badgeText: 'text-blue-700',
  },
}

function ProblemCard({ problem, onAction }) {
  const [isExpanded, setIsExpanded] = useState(false)

  const {
    name,
    severity = 'medium', // 'high', 'medium', 'low'
    description,
    rootCause,
    recommendedSolution,
    timestamp,
    autoFixAvailable = true,
  } = problem

  const config = SEVERITY_CONFIG[severity] || SEVERITY_CONFIG.medium
  const Icon = config.icon

  const handleAction = (action) => {
    if (onAction) {
      onAction(problem, action)
    }
  }

  return (
    <div
      className={clsx(
        'border-2 rounded-lg overflow-hidden transition-all duration-200',
        config.border,
        config.bg
      )}
    >
      <div
        className="p-4 cursor-pointer hover:bg-opacity-80 transition-colors"
        onClick={() => setIsExpanded(!isExpanded)}
      >
        <div className="flex items-start space-x-3">
          <Icon className={clsx('w-6 h-6 shrink-0 mt-0.5', config.color)} />

          <div className="flex-1 min-w-0">
            <div className="flex items-center justify-between mb-2">
              <div className="flex items-center space-x-2">
                <h4 className="font-semibold text-sm text-gray-900">{name}</h4>
                <span
                  className={clsx(
                    'px-2 py-0.5 text-xs font-medium rounded-full',
                    config.badgeBg,
                    config.badgeText
                  )}
                >
                  {config.label}
                </span>
              </div>
              {timestamp && (
                <span className="text-xs text-gray-500">
                  {new Date(timestamp).toLocaleTimeString()}
                </span>
              )}
            </div>

            <p className="text-sm text-gray-700 mb-2">{description}</p>

            {recommendedSolution && (
              <div className="flex items-start space-x-2 text-xs text-gray-600 bg-white bg-opacity-50 rounded p-2">
                <Wrench className="w-4 h-4 shrink-0 mt-0.5 text-blue-600" />
                <div>
                  <span className="font-medium">Recommended: </span>
                  {recommendedSolution}
                </div>
              </div>
            )}
          </div>

          <button
            className="shrink-0 text-gray-400 hover:text-gray-600 transition-colors"
            onClick={(e) => {
              e.stopPropagation()
              setIsExpanded(!isExpanded)
            }}
          >
            {isExpanded ? (
              <ChevronDown className="w-4 h-4" />
            ) : (
              <ChevronRight className="w-4 h-4" />
            )}
          </button>
        </div>
      </div>

      {isExpanded && rootCause && (
        <div className="px-4 pb-4 border-t border-gray-200 pt-3">
          <div className="bg-white bg-opacity-50 rounded p-3 mb-3">
            <h5 className="text-xs font-semibold text-gray-900 mb-1">Root Cause</h5>
            <p className="text-sm text-gray-700">{rootCause}</p>
          </div>
        </div>
      )}

      <div className="px-4 pb-4 border-t border-gray-200 pt-3">
        <div className="flex items-center space-x-2">
          {autoFixAvailable && (
            <button
              onClick={() => handleAction('auto-fix')}
              className="flex items-center space-x-1.5 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors text-sm font-medium"
            >
              <Wrench className="w-4 h-4" />
              <span>Auto-Fix</span>
            </button>
          )}

          <button
            onClick={() => handleAction('skip')}
            className="flex items-center space-x-1.5 px-4 py-2 bg-gray-200 text-gray-700 rounded-lg hover:bg-gray-300 transition-colors text-sm font-medium"
          >
            <SkipForward className="w-4 h-4" />
            <span>Skip</span>
          </button>

          <button
            onClick={() => handleAction('manual')}
            className="flex items-center space-x-1.5 px-4 py-2 bg-white border border-gray-300 text-gray-700 rounded-lg hover:bg-gray-50 transition-colors text-sm font-medium"
          >
            <Hand className="w-4 h-4" />
            <span>Manual</span>
          </button>
        </div>
      </div>
    </div>
  )
}

function ProblemList({ problems = [], onAction }) {
  if (problems.length === 0) {
    return (
      <div className="text-center py-8 text-gray-500">
        <AlertCircle className="w-12 h-12 mx-auto mb-2 opacity-50" />
        <p className="text-sm">No problems detected</p>
      </div>
    )
  }

  const severityCounts = {
    high: problems.filter(p => p.severity === 'high').length,
    medium: problems.filter(p => p.severity === 'medium').length,
    low: problems.filter(p => p.severity === 'low').length,
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between mb-3">
        <h3 className="text-sm font-semibold text-gray-900">
          Problems Detected ({problems.length})
        </h3>
        <div className="flex items-center space-x-3 text-xs">
          {severityCounts.high > 0 && (
            <div className="flex items-center space-x-1">
              <div className="w-2 h-2 bg-red-500 rounded-full" />
              <span className="text-gray-600">{severityCounts.high} high</span>
            </div>
          )}
          {severityCounts.medium > 0 && (
            <div className="flex items-center space-x-1">
              <div className="w-2 h-2 bg-yellow-500 rounded-full" />
              <span className="text-gray-600">{severityCounts.medium} medium</span>
            </div>
          )}
          {severityCounts.low > 0 && (
            <div className="flex items-center space-x-1">
              <div className="w-2 h-2 bg-blue-500 rounded-full" />
              <span className="text-gray-600">{severityCounts.low} low</span>
            </div>
          )}
        </div>
      </div>

      <div className="space-y-3 max-h-96 overflow-y-auto">
        {problems.map((problem, idx) => (
          <ProblemCard key={idx} problem={problem} onAction={onAction} />
        ))}
      </div>
    </div>
  )
}

export default ProblemCard
export { ProblemList }
