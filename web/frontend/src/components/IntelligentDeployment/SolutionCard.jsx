import React from 'react'
import { CheckCircle, XCircle, Loader2, ChevronRight } from 'lucide-react'
import clsx from 'clsx'

function SolutionCard({ solution }) {
  const {
    name,
    status = 'in_progress', // 'pending', 'in_progress', 'success', 'failed'
    steps = [],
    currentStep = 0,
    error,
    timestamp,
  } = solution

  const getStatusConfig = () => {
    switch (status) {
      case 'success':
        return {
          icon: CheckCircle,
          color: 'text-green-600',
          bg: 'bg-green-50',
          border: 'border-green-300',
        }
      case 'failed':
        return {
          icon: XCircle,
          color: 'text-red-600',
          bg: 'bg-red-50',
          border: 'border-red-300',
        }
      case 'in_progress':
        return {
          icon: Loader2,
          color: 'text-blue-600',
          bg: 'bg-blue-50',
          border: 'border-blue-300',
        }
      default:
        return {
          icon: ChevronRight,
          color: 'text-gray-600',
          bg: 'bg-gray-50',
          border: 'border-gray-300',
        }
    }
  }

  const config = getStatusConfig()
  const Icon = config.icon

  return (
    <div
      className={clsx(
        'border-2 rounded-lg overflow-hidden transition-all duration-200',
        config.border,
        config.bg
      )}
    >
      <div className="p-4">
        <div className="flex items-start space-x-3 mb-4">
          <Icon
            className={clsx('w-6 h-6 flex-shrink-0 mt-0.5', config.color, {
              'animate-spin': status === 'in_progress',
            })}
          />

          <div className="flex-1 min-w-0">
            <div className="flex items-center justify-between mb-1">
              <h4 className="font-semibold text-sm text-gray-900">{name}</h4>
              {timestamp && (
                <span className="text-xs text-gray-500">
                  {new Date(timestamp).toLocaleTimeString()}
                </span>
              )}
            </div>

            {status === 'in_progress' && (
              <p className="text-sm text-gray-600">
                Step {currentStep + 1} of {steps.length}
              </p>
            )}

            {status === 'success' && (
              <p className="text-sm text-green-600 font-medium">
                Solution applied successfully
              </p>
            )}

            {status === 'failed' && error && (
              <p className="text-sm text-red-600 font-medium">
                Failed: {error}
              </p>
            )}
          </div>
        </div>

        {/* Progress bar */}
        {steps.length > 0 && (
          <div className="mb-4">
            <div className="h-2 bg-gray-200 rounded-full overflow-hidden">
              <div
                className={clsx(
                  'h-full transition-all duration-300',
                  {
                    'bg-green-500': status === 'success',
                    'bg-red-500': status === 'failed',
                    'bg-blue-500': status === 'in_progress' || status === 'pending',
                  }
                )}
                style={{
                  width: `${status === 'success' ? 100 : ((currentStep + 1) / steps.length) * 100}%`,
                }}
              />
            </div>
          </div>
        )}

        {/* Steps */}
        {steps.length > 0 && (
          <div className="space-y-2">
            {steps.map((step, idx) => {
              const isCompleted = idx < currentStep || status === 'success'
              const isCurrent = idx === currentStep && status === 'in_progress'
              const isPending = idx > currentStep && status !== 'success'

              return (
                <div
                  key={idx}
                  className={clsx(
                    'flex items-start space-x-2 p-2 rounded transition-all duration-200',
                    {
                      'bg-green-100': isCompleted,
                      'bg-blue-100': isCurrent,
                      'bg-white bg-opacity-50': isPending,
                    }
                  )}
                >
                  <div className="flex-shrink-0 mt-0.5">
                    {isCompleted ? (
                      <CheckCircle className="w-4 h-4 text-green-600" />
                    ) : isCurrent ? (
                      <Loader2 className="w-4 h-4 text-blue-600 animate-spin" />
                    ) : (
                      <div className="w-4 h-4 rounded-full border-2 border-gray-300" />
                    )}
                  </div>

                  <div className="flex-1 min-w-0">
                    <p
                      className={clsx('text-sm', {
                        'text-gray-900 font-medium': isCurrent,
                        'text-gray-700': isCompleted,
                        'text-gray-500': isPending,
                      })}
                    >
                      {step.name || step}
                    </p>
                    {step.description && (
                      <p className="text-xs text-gray-600 mt-0.5">
                        {step.description}
                      </p>
                    )}
                  </div>

                  {isCurrent && (
                    <div className="flex space-x-1">
                      <div className="w-1.5 h-1.5 bg-blue-600 rounded-full animate-bounce" />
                      <div className="w-1.5 h-1.5 bg-blue-600 rounded-full animate-bounce" style={{ animationDelay: '0.1s' }} />
                      <div className="w-1.5 h-1.5 bg-blue-600 rounded-full animate-bounce" style={{ animationDelay: '0.2s' }} />
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        )}
      </div>
    </div>
  )
}

function SolutionList({ solutions = [] }) {
  if (solutions.length === 0) {
    return (
      <div className="text-center py-8 text-gray-500">
        <ChevronRight className="w-12 h-12 mx-auto mb-2 opacity-50" />
        <p className="text-sm">No solutions applied yet</p>
      </div>
    )
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between mb-3">
        <h3 className="text-sm font-semibold text-gray-900">
          Solutions ({solutions.length})
        </h3>
        <div className="flex items-center space-x-3 text-xs">
          <div className="flex items-center space-x-1">
            <CheckCircle className="w-4 h-4 text-green-600" />
            <span className="text-gray-600">
              {solutions.filter(s => s.status === 'success').length}
            </span>
          </div>
          <div className="flex items-center space-x-1">
            <Loader2 className="w-4 h-4 text-blue-600" />
            <span className="text-gray-600">
              {solutions.filter(s => s.status === 'in_progress').length}
            </span>
          </div>
          <div className="flex items-center space-x-1">
            <XCircle className="w-4 h-4 text-red-600" />
            <span className="text-gray-600">
              {solutions.filter(s => s.status === 'failed').length}
            </span>
          </div>
        </div>
      </div>

      <div className="space-y-3 max-h-96 overflow-y-auto">
        {solutions.map((solution, idx) => (
          <SolutionCard key={idx} solution={solution} />
        ))}
      </div>
    </div>
  )
}

export default SolutionCard
export { SolutionList }
