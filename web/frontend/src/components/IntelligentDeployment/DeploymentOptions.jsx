import React from 'react'
import { Settings, Wrench, Eye, AlertTriangle } from 'lucide-react'
import clsx from 'clsx'
import Tooltip from '../Tooltip'

function ToggleSwitch({ enabled, onChange, disabled = false }) {
  return (
    <button
      onClick={() => !disabled && onChange(!enabled)}
      disabled={disabled}
      className={clsx(
        'relative inline-flex h-6 w-11 items-center rounded-full transition-colors focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2',
        {
          'bg-blue-600': enabled,
          'bg-gray-300': !enabled,
          'opacity-50 cursor-not-allowed': disabled,
          'cursor-pointer': !disabled,
        }
      )}
    >
      <span
        className={clsx(
          'inline-block h-4 w-4 transform rounded-full bg-white transition-transform',
          {
            'translate-x-6': enabled,
            'translate-x-1': !enabled,
          }
        )}
      />
    </button>
  )
}

function DeploymentOptions({ options = {}, onChange }) {
  const defaultOptions = {
    autoHealing: true,
    dryRun: false,
    verboseLogging: false,
    stopOnFirstError: false,
    ...options,
  }

  const handleToggle = (key, value) => {
    if (onChange) {
      onChange({
        ...defaultOptions,
        [key]: value,
      })
    }
  }

  const optionsList = [
    {
      key: 'autoHealing',
      label: 'Enable Auto-Healing',
      description: 'Automatically apply fixes when problems are detected',
      icon: Wrench,
      color: 'text-blue-600',
      recommended: true,
    },
    {
      key: 'dryRun',
      label: 'Dry Run Mode',
      description: 'Simulate deployment without making actual changes',
      icon: Eye,
      color: 'text-purple-600',
    },
    {
      key: 'verboseLogging',
      label: 'Verbose Logging',
      description: 'Show detailed logs for every step of the deployment',
      icon: Settings,
      color: 'text-gray-600',
    },
    {
      key: 'stopOnFirstError',
      label: 'Stop on First Error',
      description: 'Halt deployment immediately if any error is encountered',
      icon: AlertTriangle,
      color: 'text-red-600',
    },
  ]

  return (
    <div className="space-y-4">
      <div className="flex items-center space-x-2 mb-4">
        <Settings className="w-5 h-5 text-gray-700" />
        <h3 className="text-lg font-semibold text-gray-900">Deployment Options</h3>
      </div>

      <div className="space-y-3">
        {optionsList.map((option) => {
          const Icon = option.icon
          const isEnabled = defaultOptions[option.key]

          return (
            <div
              key={option.key}
              className={clsx(
                'flex items-center justify-between p-4 border rounded-lg transition-all duration-200',
                {
                  'bg-blue-50 border-blue-200': isEnabled && option.recommended,
                  'bg-gray-50 border-gray-200': !isEnabled || !option.recommended,
                  'hover:shadow-md': true,
                }
              )}
            >
              <div className="flex items-start space-x-3 flex-1">
                <Icon className={clsx('w-5 h-5 shrink-0 mt-0.5', option.color)} />

                <div className="flex-1 min-w-0">
                  <div className="flex items-center space-x-2">
                    <label className="font-medium text-sm text-gray-900 cursor-pointer">
                      {option.label}
                    </label>
                    {option.recommended && (
                      <Tooltip content="Recommended for intelligent deployments">
                        <span className="px-2 py-0.5 text-xs font-medium bg-blue-100 text-blue-700 rounded-full cursor-help">
                          Recommended
                        </span>
                      </Tooltip>
                    )}
                  </div>
                  <p className="text-sm text-gray-600 mt-1">{option.description}</p>
                </div>
              </div>

              <div className="ml-4">
                <ToggleSwitch
                  enabled={isEnabled}
                  onChange={(value) => handleToggle(option.key, value)}
                />
              </div>
            </div>
          )
        })}
      </div>

      {/* Summary */}
      <div className="mt-6 p-4 bg-linear-to-r from-blue-50 to-purple-50 border border-blue-200 rounded-lg">
        <div className="flex items-start space-x-2">
          <Settings className="w-5 h-5 text-blue-600 shrink-0 mt-0.5" />
          <div className="text-sm text-gray-700">
            <p className="font-medium mb-1">Current Configuration</p>
            <ul className="space-y-1 text-xs">
              {defaultOptions.autoHealing && (
                <li className="flex items-center space-x-2">
                  <div className="w-1.5 h-1.5 bg-green-500 rounded-full" />
                  <span>Automatic healing enabled</span>
                </li>
              )}
              {defaultOptions.dryRun && (
                <li className="flex items-center space-x-2">
                  <div className="w-1.5 h-1.5 bg-purple-500 rounded-full" />
                  <span>Running in simulation mode</span>
                </li>
              )}
              {defaultOptions.verboseLogging && (
                <li className="flex items-center space-x-2">
                  <div className="w-1.5 h-1.5 bg-gray-500 rounded-full" />
                  <span>Verbose logging active</span>
                </li>
              )}
              {defaultOptions.stopOnFirstError && (
                <li className="flex items-center space-x-2">
                  <div className="w-1.5 h-1.5 bg-red-500 rounded-full" />
                  <span>Will stop on first error</span>
                </li>
              )}
              {!defaultOptions.autoHealing && !defaultOptions.dryRun && !defaultOptions.verboseLogging && !defaultOptions.stopOnFirstError && (
                <li className="text-gray-500 italic">Standard deployment mode</li>
              )}
            </ul>
          </div>
        </div>
      </div>
    </div>
  )
}

export default DeploymentOptions
