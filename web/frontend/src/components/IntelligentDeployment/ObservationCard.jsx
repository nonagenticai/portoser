import React, { useState } from 'react'
import { CheckCircle, XCircle, ChevronDown, ChevronRight, Eye } from 'lucide-react'
import clsx from 'clsx'

function ObservationCard({ observation }) {
  const [isExpanded, setIsExpanded] = useState(false)

  const {
    name,
    status = 'success', // 'success', 'failed', 'pending'
    message,
    details,
    timestamp,
  } = observation

  const getStatusConfig = () => {
    switch (status) {
      case 'success':
        return {
          icon: CheckCircle,
          color: 'text-green-600',
          bg: 'bg-green-50',
          border: 'border-green-200',
        }
      case 'failed':
        return {
          icon: XCircle,
          color: 'text-red-600',
          bg: 'bg-red-50',
          border: 'border-red-200',
        }
      case 'pending':
        return {
          icon: Eye,
          color: 'text-blue-600',
          bg: 'bg-blue-50',
          border: 'border-blue-200',
        }
      default:
        return {
          icon: Eye,
          color: 'text-gray-600',
          bg: 'bg-gray-50',
          border: 'border-gray-200',
        }
    }
  }

  const config = getStatusConfig()
  const Icon = config.icon

  return (
    <div
      className={clsx(
        'border rounded-lg overflow-hidden transition-all duration-200',
        config.border,
        config.bg
      )}
    >
      <div
        className="p-3 cursor-pointer hover:bg-opacity-80 transition-colors"
        onClick={() => setIsExpanded(!isExpanded)}
      >
        <div className="flex items-start space-x-3">
          <Icon className={clsx('w-5 h-5 shrink-0 mt-0.5', config.color)} />

          <div className="flex-1 min-w-0">
            <div className="flex items-center justify-between">
              <h4 className="font-medium text-sm text-gray-900">{name}</h4>
              {timestamp && (
                <span className="text-xs text-gray-500">
                  {new Date(timestamp).toLocaleTimeString()}
                </span>
              )}
            </div>
            {message && (
              <p className="text-sm text-gray-600 mt-1">{message}</p>
            )}
          </div>

          {details && (
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
          )}
        </div>
      </div>

      {isExpanded && details && (
        <div className="px-3 pb-3 border-t border-gray-200">
          <div className="pt-3 space-y-2">
            {typeof details === 'string' ? (
              <p className="text-sm text-gray-700">{details}</p>
            ) : (
              <div className="bg-white rounded p-3 font-mono text-xs">
                <pre className="whitespace-pre-wrap wrap-break-word">
                  {JSON.stringify(details, null, 2)}
                </pre>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  )
}

function ObservationList({ observations = [] }) {
  if (observations.length === 0) {
    return (
      <div className="text-center py-8 text-gray-500">
        <Eye className="w-12 h-12 mx-auto mb-2 opacity-50" />
        <p className="text-sm">No observations yet</p>
      </div>
    )
  }

  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between mb-3">
        <h3 className="text-sm font-semibold text-gray-900">
          Observations ({observations.length})
        </h3>
        <div className="flex items-center space-x-3 text-xs">
          <div className="flex items-center space-x-1">
            <CheckCircle className="w-4 h-4 text-green-600" />
            <span className="text-gray-600">
              {observations.filter(o => o.status === 'success').length}
            </span>
          </div>
          <div className="flex items-center space-x-1">
            <XCircle className="w-4 h-4 text-red-600" />
            <span className="text-gray-600">
              {observations.filter(o => o.status === 'failed').length}
            </span>
          </div>
        </div>
      </div>

      <div className="space-y-2 max-h-96 overflow-y-auto">
        {observations.map((observation, idx) => (
          <ObservationCard key={idx} observation={observation} />
        ))}
      </div>
    </div>
  )
}

export default ObservationCard
export { ObservationList }
