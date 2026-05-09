import React from 'react'
import { Eye, Stethoscope, Wrench, BookOpen, CheckCircle, Circle } from 'lucide-react'
import clsx from 'clsx'

const PHASES = [
  {
    id: 1,
    name: 'GO TO SEE',
    emoji: '🔍',
    icon: Eye,
    description: 'Observing system state',
    color: 'blue',
  },
  {
    id: 2,
    name: 'GRASP THE SITUATION',
    emoji: '📊',
    icon: Stethoscope,
    description: 'Diagnosing issues',
    color: 'purple',
  },
  {
    id: 3,
    name: 'GET TO SOLUTION',
    emoji: '🔧',
    icon: Wrench,
    description: 'Auto-healing',
    color: 'orange',
  },
  {
    id: 4,
    name: 'GET TO STANDARDIZATION',
    emoji: '📝',
    icon: BookOpen,
    description: 'Learning & improving',
    color: 'green',
  },
]

const getColorClasses = (color, isActive, isCompleted) => {
  if (isCompleted) {
    return {
      bg: 'bg-green-100',
      border: 'border-green-500',
      text: 'text-green-700',
      icon: 'text-green-600',
    }
  }

  if (isActive) {
    const colors = {
      blue: {
        bg: 'bg-blue-100',
        border: 'border-blue-500',
        text: 'text-blue-700',
        icon: 'text-blue-600',
      },
      purple: {
        bg: 'bg-purple-100',
        border: 'border-purple-500',
        text: 'text-purple-700',
        icon: 'text-purple-600',
      },
      orange: {
        bg: 'bg-orange-100',
        border: 'border-orange-500',
        text: 'text-orange-700',
        icon: 'text-orange-600',
      },
      green: {
        bg: 'bg-green-100',
        border: 'border-green-500',
        text: 'text-green-700',
        icon: 'text-green-600',
      },
    }
    return colors[color]
  }

  return {
    bg: 'bg-gray-50',
    border: 'border-gray-300',
    text: 'text-gray-500',
    icon: 'text-gray-400',
  }
}

function DeploymentPhases({ currentPhase = 1, completedPhases = [] }) {
  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between mb-2">
        <h3 className="text-lg font-semibold text-gray-900">Deployment Phases</h3>
        <div className="text-sm text-gray-600">
          Phase {currentPhase} of {PHASES.length}
        </div>
      </div>

      {/* Progress bar */}
      <div className="relative">
        <div className="h-2 bg-gray-200 rounded-full overflow-hidden">
          <div
            className="h-full bg-gradient-to-r from-blue-500 via-purple-500 to-green-500 transition-all duration-500 ease-out"
            style={{ width: `${(completedPhases.length / PHASES.length) * 100}%` }}
          />
        </div>
      </div>

      {/* Phase cards */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
        {PHASES.map((phase) => {
          const isActive = phase.id === currentPhase
          const isCompleted = completedPhases.includes(phase.id)
          const colorClasses = getColorClasses(phase.color, isActive, isCompleted)
          const Icon = phase.icon

          return (
            <div
              key={phase.id}
              className={clsx(
                'relative p-4 border-2 rounded-lg transition-all duration-300',
                colorClasses.bg,
                colorClasses.border,
                {
                  'shadow-lg scale-105 ring-2 ring-offset-2': isActive,
                  'opacity-60': !isActive && !isCompleted,
                }
              )}
            >
              <div className="flex items-start space-x-3">
                <div className={clsx('flex-shrink-0 mt-0.5', colorClasses.icon)}>
                  {isCompleted ? (
                    <CheckCircle className="w-6 h-6" />
                  ) : (
                    <Icon className={clsx('w-6 h-6', { 'animate-pulse': isActive })} />
                  )}
                </div>

                <div className="flex-1 min-w-0">
                  <div className="flex items-center space-x-2 mb-1">
                    <span className="text-xl">{phase.emoji}</span>
                    <h4 className={clsx('font-semibold text-sm', colorClasses.text)}>
                      {phase.name}
                    </h4>
                  </div>
                  <p className="text-xs text-gray-600">{phase.description}</p>

                  {isActive && (
                    <div className="mt-2 flex items-center space-x-2">
                      <div className="flex space-x-1">
                        <Circle className="w-2 h-2 fill-current animate-bounce" />
                        <Circle className="w-2 h-2 fill-current animate-bounce" style={{ animationDelay: '0.1s' }} />
                        <Circle className="w-2 h-2 fill-current animate-bounce" style={{ animationDelay: '0.2s' }} />
                      </div>
                      <span className="text-xs font-medium">In Progress</span>
                    </div>
                  )}

                  {isCompleted && (
                    <div className="mt-2 text-xs font-medium text-green-600">
                      Completed
                    </div>
                  )}
                </div>
              </div>
            </div>
          )
        })}
      </div>

      {/* Timeline view */}
      <div className="mt-6 flex items-center justify-between px-4">
        {PHASES.map((phase, idx) => {
          const isCompleted = completedPhases.includes(phase.id)
          const isActive = phase.id === currentPhase

          return (
            <React.Fragment key={phase.id}>
              <div className="flex flex-col items-center">
                <div
                  className={clsx(
                    'w-10 h-10 rounded-full flex items-center justify-center border-2 transition-all duration-300',
                    {
                      'bg-green-500 border-green-600 text-white': isCompleted,
                      'bg-blue-500 border-blue-600 text-white animate-pulse': isActive && !isCompleted,
                      'bg-gray-200 border-gray-300 text-gray-500': !isActive && !isCompleted,
                    }
                  )}
                >
                  {isCompleted ? (
                    <CheckCircle className="w-5 h-5" />
                  ) : (
                    <span className="text-xs font-bold">{phase.id}</span>
                  )}
                </div>
                <div className="mt-2 text-xs text-center text-gray-600 max-w-[80px]">
                  {phase.emoji}
                </div>
              </div>

              {idx < PHASES.length - 1 && (
                <div
                  className={clsx(
                    'flex-1 h-0.5 mx-2 transition-all duration-300',
                    {
                      'bg-green-500': completedPhases.includes(phase.id + 1),
                      'bg-gray-300': !completedPhases.includes(phase.id + 1),
                    }
                  )}
                />
              )}
            </React.Fragment>
          )
        })}
      </div>
    </div>
  )
}

export default DeploymentPhases
