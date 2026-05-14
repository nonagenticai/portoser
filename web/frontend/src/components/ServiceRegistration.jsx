import React, { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { createService, fetchMachines } from '../api/client'
import { X, Package, Box, Database, Cpu } from 'lucide-react'
import { InfoIcon } from './Tooltip'

const DEPLOYMENT_TYPES = [
  {
    value: 'docker',
    label: 'Docker',
    icon: Box,
    description: 'Containerized application using Docker Compose',
    requirements: 'Requires docker-compose.yml file',
    example: '/Users/user/services/my_service/docker-compose.yml'
  },
  {
    value: 'native',
    label: 'Native (Homebrew)',
    icon: Database,
    description: 'System service installed via Homebrew or package manager',
    requirements: 'Requires service.yml configuration file',
    example: '/Users/user/services/postgres/service.yml'
  },
  {
    value: 'local',
    label: 'Local (Python)',
    icon: Cpu,
    description: 'Python application managed with Poetry, UV, or virtual env',
    requirements: 'Requires service.yml with start/stop commands',
    example: '/Users/user/services/myservice/service.yml'
  }
]

function ServiceRegistration({ onClose }) {
  const [formData, setFormData] = useState({
    name: '',
    hostname: '',
    current_host: '',
    deployment_type: 'docker',
    docker_compose: '',
    service_file: '',
    service_name: '',
  })

  const { data: machinesData } = useQuery({
    queryKey: ['machines'],
    queryFn: fetchMachines,
  })

  const queryClient = useQueryClient()

  const createMutation = useMutation({
    mutationFn: createService,
    onSuccess: () => {
      queryClient.invalidateQueries(['services'])
      onClose()
    },
  })

  const handleSubmit = (e) => {
    e.preventDefault()

    const payload = {
      name: formData.name,
      hostname: formData.hostname || `${formData.name.replace(/_/g, '-')}.internal`,
      current_host: formData.current_host,
      deployment_type: formData.deployment_type,
    }

    if (formData.deployment_type === 'docker' && formData.docker_compose) {
      payload.docker_compose = formData.docker_compose
      if (formData.service_name) {
        payload.service_name = formData.service_name
      }
    }

    if ((formData.deployment_type === 'native' || formData.deployment_type === 'local') && formData.service_file) {
      payload.service_file = formData.service_file
    }

    createMutation.mutate(payload)
  }

  const machines = machinesData || []
  const selectedType = DEPLOYMENT_TYPES.find(t => t.value === formData.deployment_type)

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
      <div className="bg-white rounded-lg shadow-xl max-w-2xl w-full mx-4 max-h-[90vh] overflow-y-auto">
        <div className="flex items-center justify-between p-6 border-b border-gray-200 sticky top-0 bg-white z-10">
          <div className="flex items-center space-x-3">
            <Package className="w-6 h-6 text-primary" />
            <h2 className="text-xl font-semibold text-gray-900">Register Service</h2>
          </div>
          <button
            onClick={onClose}
            className="text-gray-400 hover:text-gray-600 transition-colors"
          >
            <X className="w-6 h-6" />
          </button>
        </div>

        <form onSubmit={handleSubmit} className="p-6 space-y-5">
          {/* Service Name */}
          <div>
            <label className="flex items-center space-x-2 text-sm font-medium text-gray-700 mb-1">
              <span>Service Name <span className="text-red-500">*</span></span>
              <InfoIcon
                content="Unique identifier for this service. Use lowercase with underscores (e.g., my_service, kag_orchestrator). This name is used in CLI commands and throughout the system."
                position="right"
              />
            </label>
            <input
              type="text"
              required
              value={formData.name}
              onChange={(e) => setFormData({ ...formData, name: e.target.value })}
              className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent"
              placeholder="my_service"
            />
            <p className="mt-1 text-xs text-gray-500">Examples: requirements, kag_orchestrator, storage_service</p>
          </div>

          {/* Hostname */}
          <div>
            <label className="flex items-center space-x-2 text-sm font-medium text-gray-700 mb-1">
              <span>Hostname</span>
              <InfoIcon
                content="The internal domain name for accessing this service (e.g., my-service.internal). Caddy uses this for reverse proxy routing. Leave empty to auto-generate from service name."
                position="right"
              />
            </label>
            <input
              type="text"
              value={formData.hostname}
              onChange={(e) => setFormData({ ...formData, hostname: e.target.value })}
              className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent"
              placeholder={`${formData.name.replace(/_/g, '-') || 'my-service'}.internal`}
            />
            <p className="mt-1 text-xs text-gray-500">
              Auto-generated: <code className="bg-gray-100 px-1 rounded">{formData.name.replace(/_/g, '-') || 'service-name'}.internal</code>
            </p>
          </div>

          {/* Initial Machine */}
          <div>
            <label className="flex items-center space-x-2 text-sm font-medium text-gray-700 mb-1">
              <span>Initial Machine <span className="text-red-500">*</span></span>
              <InfoIcon
                content="Select which machine to initially deploy this service on. You can move it to other machines later using drag & drop in the main interface."
                position="right"
              />
            </label>
            <select
              required
              value={formData.current_host}
              onChange={(e) => setFormData({ ...formData, current_host: e.target.value })}
              className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent"
            >
              <option value="">Select a machine</option>
              {machines.map(machine => (
                <option key={machine.name} value={machine.name}>
                  {machine.name} ({machine.ip})
                  {machine.roles?.length > 0 && ` - ${machine.roles.join(', ')}`}
                </option>
              ))}
            </select>
            {machines.length === 0 && (
              <p className="mt-1 text-xs text-red-500">No machines available. Please register a machine first.</p>
            )}
          </div>

          {/* Deployment Type */}
          <div>
            <label className="flex items-center space-x-2 text-sm font-medium text-gray-700 mb-2">
              <span>Deployment Type <span className="text-red-500">*</span></span>
              <InfoIcon
                content="How this service is deployed and managed. Docker for containers, Native for system services (Homebrew), or Local for Python applications managed with Poetry/UV."
                position="right"
              />
            </label>

            <div className="grid grid-cols-1 gap-3">
              {DEPLOYMENT_TYPES.map(type => {
                const Icon = type.icon
                return (
                  <button
                    key={type.value}
                    type="button"
                    onClick={() => setFormData({ ...formData, deployment_type: type.value })}
                    className={`
                      flex items-start p-4 rounded-lg border-2 transition-all text-left
                      ${formData.deployment_type === type.value
                        ? 'border-primary bg-primary/5'
                        : 'border-gray-200 hover:border-gray-300 bg-white'
                      }
                    `}
                  >
                    <Icon className={`w-5 h-5 mr-3 mt-0.5 shrink-0 ${
                      formData.deployment_type === type.value ? 'text-primary' : 'text-gray-400'
                    }`} />
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center space-x-2">
                        <span className="text-sm font-semibold text-gray-900">{type.label}</span>
                        {formData.deployment_type === type.value && (
                          <span className="text-xs bg-primary text-white px-2 py-0.5 rounded">Selected</span>
                        )}
                      </div>
                      <p className="text-sm text-gray-600 mt-1">{type.description}</p>
                      <p className="text-xs text-gray-500 mt-1">
                        <strong>Requirements:</strong> {type.requirements}
                      </p>
                    </div>
                  </button>
                )
              })}
            </div>
          </div>

          {/* Docker-specific fields */}
          {formData.deployment_type === 'docker' && (
            <div className="space-y-4 p-4 bg-blue-50 border border-blue-100 rounded-lg">
              <h3 className="text-sm font-semibold text-gray-900 flex items-center">
                <Box className="w-4 h-4 mr-2 text-primary" />
                Docker Configuration
              </h3>

              <div>
                <label className="flex items-center space-x-2 text-sm font-medium text-gray-700 mb-1">
                  <span>Docker Compose Path</span>
                  <InfoIcon
                    content="Absolute path to the docker-compose.yml file for this service. This file defines containers, networks, volumes, and environment variables."
                    position="right"
                  />
                </label>
                <input
                  type="text"
                  value={formData.docker_compose}
                  onChange={(e) => setFormData({ ...formData, docker_compose: e.target.value })}
                  className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent bg-white"
                  placeholder="/Users/user/services/my_service/docker-compose.yml"
                />
                <p className="mt-1 text-xs text-gray-600">
                  Example: {selectedType?.example}
                </p>
              </div>

              <div>
                <label className="flex items-center space-x-2 text-sm font-medium text-gray-700 mb-1">
                  <span>Service Name (Multi-Service Compose)</span>
                  <InfoIcon
                    content="If your docker-compose.yml contains multiple services (e.g., frontend, backend, database), specify which service name this registration refers to. Leave empty for single-service compose files."
                    position="right"
                  />
                </label>
                <input
                  type="text"
                  value={formData.service_name}
                  onChange={(e) => setFormData({ ...formData, service_name: e.target.value })}
                  className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent bg-white"
                  placeholder="backend"
                />
                <p className="mt-1 text-xs text-gray-600">
                  Only needed for multi-service docker-compose files. Examples: frontend, backend, api
                </p>
              </div>
            </div>
          )}

          {/* Native/Local-specific fields */}
          {(formData.deployment_type === 'native' || formData.deployment_type === 'local') && (
            <div className="space-y-4 p-4 bg-purple-50 border border-purple-100 rounded-lg">
              <h3 className="text-sm font-semibold text-gray-900 flex items-center">
                {formData.deployment_type === 'native' ? (
                  <><Database className="w-4 h-4 mr-2 text-primary" /> Native Service Configuration</>
                ) : (
                  <><Cpu className="w-4 h-4 mr-2 text-primary" /> Local Python Configuration</>
                )}
              </h3>

              <div>
                <label className="flex items-center space-x-2 text-sm font-medium text-gray-700 mb-1">
                  <span>Service File Path</span>
                  <InfoIcon
                    content={`Absolute path to service.yml file that defines how to start, stop, and health check this service. ${
                      formData.deployment_type === 'local'
                        ? 'For Python apps, this includes poetry/uv commands and virtual environment paths.'
                        : 'For native services, this includes brew/systemctl commands.'
                    }`}
                    position="right"
                  />
                </label>
                <input
                  type="text"
                  value={formData.service_file}
                  onChange={(e) => setFormData({ ...formData, service_file: e.target.value })}
                  className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent bg-white"
                  placeholder={selectedType?.example}
                />
                <p className="mt-1 text-xs text-gray-600">
                  The service.yml must define: start, stop, restart, status, and healthcheck commands
                </p>
              </div>

              {formData.deployment_type === 'local' && (
                <div className="bg-white border border-purple-200 rounded p-3">
                  <p className="text-xs text-gray-700 font-medium mb-2">Example service.yml for Python:</p>
                  <pre className="text-xs text-gray-600 overflow-x-auto">
{`name: my_service
start: poetry run python main.py
stop: pkill -f "python main.py"
healthcheck: curl -f http://localhost:3000/health`}
                  </pre>
                </div>
              )}
            </div>
          )}

          {createMutation.isError && (
            <div className="p-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-600">
              <strong>Failed to register service.</strong>
              <p className="mt-1">
                {createMutation.error?.response?.data?.detail || 'Please check all fields and try again.'}
              </p>
            </div>
          )}

          <div className="flex justify-end space-x-3 pt-4 border-t border-gray-200">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2 text-gray-600 hover:text-gray-900 transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={createMutation.isPending || machines.length === 0}
              className="px-6 py-2 bg-primary text-white rounded-lg hover:bg-blue-600 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {createMutation.isPending ? 'Registering...' : 'Register Service'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}

export default ServiceRegistration
