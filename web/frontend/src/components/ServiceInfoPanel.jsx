import React from 'react'
import { X, Info, Server, Globe, Package, Database, Box, Key, Lock } from 'lucide-react'
import clsx from 'clsx'

/**
 * ServiceInfoPanel Component
 * Displays comprehensive service information in a modal
 */
function ServiceInfoPanel({ service, onClose }) {
  const getServiceIcon = (type) => {
    switch (type) {
      case 'docker':
        return <Box className="w-5 h-5" />
      case 'native':
        return <Database className="w-5 h-5" />
      case 'local':
        return <Package className="w-5 h-5" />
      default:
        return <Package className="w-5 h-5" />
    }
  }

  const getTypeColor = (type) => {
    switch (type) {
      case 'docker':
        return 'bg-blue-100 text-blue-700 border-blue-200'
      case 'native':
        return 'bg-green-100 text-green-700 border-green-200'
      case 'local':
        return 'bg-purple-100 text-purple-700 border-purple-200'
      default:
        return 'bg-gray-100 text-gray-700 border-gray-200'
    }
  }

  const getTypeDescription = (type) => {
    switch (type) {
      case 'docker':
        return 'Containerized application running in Docker. Can be easily moved between machines.'
      case 'native':
        return 'System service installed via Homebrew or package manager. Requires dependencies on target machine.'
      case 'local':
        return 'Python application running with Poetry/UV. Managed via virtual environment.'
      default:
        return 'Service deployment type'
    }
  }

  const InfoRow = ({ icon: Icon, label, value, badge = false, badgeColor = '' }) => (
    <div className="flex items-start space-x-3 py-3 border-b border-gray-100 last:border-0">
      <div className="p-2 bg-gray-100 rounded-lg">
        <Icon className="w-4 h-4 text-gray-600" />
      </div>
      <div className="flex-1 min-w-0">
        <dt className="text-sm font-medium text-gray-500">{label}</dt>
        {badge ? (
          <dd className={clsx('mt-1 inline-flex items-center px-3 py-1 rounded-full text-sm font-medium border', badgeColor)}>
            {value || 'Not configured'}
          </dd>
        ) : (
          <dd className="mt-1 text-sm text-gray-900 wrap-break-word">{value || 'N/A'}</dd>
        )}
      </div>
    </div>
  )

  return (
    <div className="fixed inset-0 z-50 overflow-hidden bg-black bg-opacity-50 flex items-center justify-center p-4">
      <div className="bg-white rounded-lg shadow-2xl max-w-3xl w-full max-h-[90vh] overflow-hidden flex flex-col">
        {/* Header */}
        <div className="px-6 py-4 border-b border-gray-200 bg-linear-to-r from-blue-50 to-purple-50">
          <div className="flex items-center justify-between">
            <div className="flex items-center space-x-3">
              <div className="p-2 bg-blue-100 rounded-lg">
                <Info className="w-6 h-6 text-blue-600" />
              </div>
              <div>
                <h2 className="text-2xl font-bold text-gray-900">{service.name}</h2>
                <p className="text-sm text-gray-600 mt-1">Service Information</p>
              </div>
            </div>

            <button
              onClick={onClose}
              className="p-2 hover:bg-gray-100 rounded-lg transition-colors"
            >
              <X className="w-5 h-5 text-gray-600" />
            </button>
          </div>
        </div>

        {/* Content */}
        <div className="flex-1 overflow-y-auto p-6">
          <div className="space-y-6">
            {/* Deployment Type */}
            <div className="bg-gray-50 border border-gray-200 rounded-lg p-4">
              <div className="flex items-center space-x-3 mb-3">
                <div className={clsx('p-2 rounded-lg', getTypeColor(service.deployment_type))}>
                  {getServiceIcon(service.deployment_type)}
                </div>
                <div>
                  <h3 className="text-lg font-semibold text-gray-900">Deployment Type</h3>
                  <span className={clsx('inline-block mt-1 px-3 py-1 rounded-full text-sm font-medium border', getTypeColor(service.deployment_type))}>
                    {service.deployment_type}
                  </span>
                </div>
              </div>
              <p className="text-sm text-gray-600 mt-2">
                {getTypeDescription(service.deployment_type)}
              </p>
            </div>

            {/* Basic Information */}
            <div className="bg-white border border-gray-200 rounded-lg p-4">
              <h3 className="text-lg font-semibold text-gray-900 mb-4">Configuration</h3>
              <dl className="space-y-0 divide-y divide-gray-100">
                <InfoRow
                  icon={Globe}
                  label="Hostname"
                  value={service.hostname}
                />
                <InfoRow
                  icon={Server}
                  label="Current Machine"
                  value={service.machine_name || service.current_host}
                />
                <InfoRow
                  icon={Package}
                  label="Port"
                  value={service.port ? `${service.port}` : 'Not exposed'}
                />
              </dl>
            </div>

            {/* Security */}
            {(service.tls_enabled || service.requires_auth) && (
              <div className="bg-white border border-gray-200 rounded-lg p-4">
                <h3 className="text-lg font-semibold text-gray-900 mb-4">Security</h3>
                <dl className="space-y-0 divide-y divide-gray-100">
                  {service.tls_enabled && (
                    <InfoRow
                      icon={Lock}
                      label="TLS/SSL"
                      value="Enabled"
                      badge={true}
                      badgeColor="bg-green-100 text-green-700 border-green-200"
                    />
                  )}
                  {service.requires_auth && (
                    <InfoRow
                      icon={Key}
                      label="Authentication"
                      value="Required"
                      badge={true}
                      badgeColor="bg-blue-100 text-blue-700 border-blue-200"
                    />
                  )}
                </dl>
              </div>
            )}

            {/* Dependencies */}
            {service.dependencies && service.dependencies.length > 0 && (
              <div className="bg-white border border-gray-200 rounded-lg p-4">
                <h3 className="text-lg font-semibold text-gray-900 mb-4">Dependencies</h3>
                <div className="flex flex-wrap gap-2">
                  {service.dependencies.map((dep, idx) => (
                    <span
                      key={idx}
                      className="inline-flex items-center px-3 py-1 rounded-full text-sm bg-gray-100 text-gray-700 border border-gray-200"
                    >
                      {dep}
                    </span>
                  ))}
                </div>
              </div>
            )}

            {/* Description */}
            {service.description && (
              <div className="bg-white border border-gray-200 rounded-lg p-4">
                <h3 className="text-lg font-semibold text-gray-900 mb-2">Description</h3>
                <p className="text-sm text-gray-600">{service.description}</p>
              </div>
            )}

            {/* Docker Compose Path */}
            {service.docker_compose && (
              <div className="bg-gray-50 border border-gray-200 rounded-lg p-4">
                <h3 className="text-sm font-medium text-gray-700 mb-2">Docker Compose File</h3>
                <code className="text-xs text-gray-600 bg-white px-3 py-2 rounded border border-gray-200 block overflow-x-auto">
                  {service.docker_compose}
                </code>
              </div>
            )}

            {/* Service File Path */}
            {service.service_file && (
              <div className="bg-gray-50 border border-gray-200 rounded-lg p-4">
                <h3 className="text-sm font-medium text-gray-700 mb-2">Service File</h3>
                <code className="text-xs text-gray-600 bg-white px-3 py-2 rounded border border-gray-200 block overflow-x-auto">
                  {service.service_file}
                </code>
              </div>
            )}
          </div>
        </div>

        {/* Footer */}
        <div className="px-6 py-4 border-t border-gray-200 bg-gray-50 flex justify-end">
          <button
            onClick={onClose}
            className="px-4 py-2 bg-gray-200 text-gray-700 rounded-lg hover:bg-gray-300 transition-colors font-medium"
          >
            Close
          </button>
        </div>
      </div>
    </div>
  )
}

export default ServiceInfoPanel
