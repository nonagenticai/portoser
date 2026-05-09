import React, { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { createMachine } from '../api/client'
import { X, Server, Tag } from 'lucide-react'
import { InfoIcon } from './Tooltip'

// Common machine roles with descriptions
const COMMON_ROLES = [
  { value: 'caddy_ingress', label: 'Caddy Ingress', description: 'Reverse proxy & load balancer' },
  { value: 'database', label: 'Database', description: 'PostgreSQL, Redis, etc.' },
  { value: 'graph_database', label: 'Graph Database', description: 'Neo4j, ArangoDB' },
  { value: 'docker_services', label: 'Docker Services', description: 'Containerized applications' },
  { value: 'native_services', label: 'Native Services', description: 'Homebrew/system services' },
  { value: 'web', label: 'Web Services', description: 'HTTP/API services' },
  { value: 'worker', label: 'Worker', description: 'Background job processing' },
  { value: 'ml', label: 'ML/AI', description: 'Machine learning services' },
  { value: 'cache', label: 'Cache', description: 'Redis, Memcached' },
  { value: 'message_queue', label: 'Message Queue', description: 'RabbitMQ, Kafka' },
  { value: 'monitoring', label: 'Monitoring', description: 'Grafana, Prometheus' },
  { value: 'storage', label: 'Storage', description: 'File storage, S3-compatible' },
]

function MachineRegistration({ onClose }) {
  const [formData, setFormData] = useState({
    name: '',
    ip: '',
    ssh_user: '',
    roles: [],
  })
  const [customRole, setCustomRole] = useState('')

  const queryClient = useQueryClient()

  const createMutation = useMutation({
    mutationFn: createMachine,
    onSuccess: () => {
      queryClient.invalidateQueries(['machines'])
      onClose()
    },
  })

  const handleSubmit = (e) => {
    e.preventDefault()

    const payload = {
      name: formData.name,
      ip: formData.ip,
      ssh_user: formData.ssh_user,
      roles: formData.roles,
    }

    createMutation.mutate(payload)
  }

  const toggleRole = (role) => {
    setFormData(prev => ({
      ...prev,
      roles: prev.roles.includes(role)
        ? prev.roles.filter(r => r !== role)
        : [...prev.roles, role]
    }))
  }

  const addCustomRole = () => {
    if (customRole.trim() && !formData.roles.includes(customRole.trim())) {
      setFormData(prev => ({
        ...prev,
        roles: [...prev.roles, customRole.trim()]
      }))
      setCustomRole('')
    }
  }

  const removeRole = (role) => {
    setFormData(prev => ({
      ...prev,
      roles: prev.roles.filter(r => r !== role)
    }))
  }

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
      <div className="bg-white rounded-lg shadow-xl max-w-2xl w-full mx-4 max-h-[90vh] overflow-y-auto">
        <div className="flex items-center justify-between p-6 border-b border-gray-200 sticky top-0 bg-white">
          <div className="flex items-center space-x-3">
            <Server className="w-6 h-6 text-primary" />
            <h2 className="text-xl font-semibold text-gray-900">Register Machine</h2>
          </div>
          <button
            onClick={onClose}
            className="text-gray-400 hover:text-gray-600 transition-colors"
          >
            <X className="w-6 h-6" />
          </button>
        </div>

        <form onSubmit={handleSubmit} className="p-6 space-y-5">
          {/* Machine Name */}
          <div>
            <label className="flex items-center space-x-2 text-sm font-medium text-gray-700 mb-1">
              <span>Machine Name <span className="text-red-500">*</span></span>
              <InfoIcon
                content="Unique identifier for this machine. Use a short, descriptive name. This name will be used in CLI commands and the registry."
                position="right"
              />
            </label>
            <input
              type="text"
              required
              value={formData.name}
              onChange={(e) => setFormData({ ...formData, name: e.target.value })}
              className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent"
              placeholder="my-host"
            />
            <p className="mt-1 text-xs text-gray-500">Example: my-host, macbook-pro, server01</p>
          </div>

          {/* IP Address */}
          <div>
            <label className="flex items-center space-x-2 text-sm font-medium text-gray-700 mb-1">
              <span>IP Address <span className="text-red-500">*</span></span>
              <InfoIcon
                content="The local network IP address of this machine. This must be accessible from other machines in your cluster via SSH and HTTP/HTTPS. Use static IPs or DHCP reservations."
                position="right"
              />
            </label>
            <input
              type="text"
              required
              value={formData.ip}
              onChange={(e) => setFormData({ ...formData, ip: e.target.value })}
              className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent"
              placeholder="10.0.0.100"
            />
            <p className="mt-1 text-xs text-gray-500">Must be reachable from other machines. Format: 10.0.x.x, 172.16.x.x, or any routable address</p>
          </div>

          {/* SSH User */}
          <div>
            <label className="flex items-center space-x-2 text-sm font-medium text-gray-700 mb-1">
              <span>SSH User <span className="text-red-500">*</span></span>
              <InfoIcon
                content="Username for SSH connections to this machine. Ensure this user has passwordless SSH access (using SSH keys) and appropriate sudo permissions for deployments."
                position="right"
              />
            </label>
            <input
              type="text"
              required
              value={formData.ssh_user}
              onChange={(e) => setFormData({ ...formData, ssh_user: e.target.value })}
              className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent"
              placeholder="ubuntu"
            />
            <p className="mt-1 text-xs text-gray-500">
              Ensure SSH key authentication is configured: <code className="text-xs bg-gray-100 px-1 rounded">ssh-copy-id {formData.ssh_user || 'user'}@{formData.ip || 'ip'}</code>
            </p>
          </div>

          {/* Roles */}
          <div>
            <label className="flex items-center space-x-2 text-sm font-medium text-gray-700 mb-2">
              <span>Machine Roles</span>
              <InfoIcon
                content="Roles help organize and categorize machines by their primary purpose. They're used for filtering, organization, and automated service placement suggestions. Select all that apply."
                position="right"
              />
            </label>

            {/* Common Roles */}
            <div className="grid grid-cols-2 gap-2 mb-3">
              {COMMON_ROLES.map(role => (
                <button
                  key={role.value}
                  type="button"
                  onClick={() => toggleRole(role.value)}
                  className={`
                    flex items-start p-3 rounded-lg border-2 transition-all text-left
                    ${formData.roles.includes(role.value)
                      ? 'border-primary bg-primary/5'
                      : 'border-gray-200 hover:border-gray-300 bg-white'
                    }
                  `}
                >
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center space-x-2">
                      <div className={`
                        w-4 h-4 rounded border-2 flex items-center justify-center flex-shrink-0
                        ${formData.roles.includes(role.value)
                          ? 'border-primary bg-primary'
                          : 'border-gray-300'
                        }
                      `}>
                        {formData.roles.includes(role.value) && (
                          <svg className="w-3 h-3 text-white" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7" />
                          </svg>
                        )}
                      </div>
                      <span className="text-sm font-medium text-gray-900">{role.label}</span>
                    </div>
                    <p className="text-xs text-gray-500 mt-1 ml-6">{role.description}</p>
                  </div>
                </button>
              ))}
            </div>

            {/* Selected Roles */}
            {formData.roles.length > 0 && (
              <div className="mb-3">
                <p className="text-xs text-gray-600 mb-2">Selected roles:</p>
                <div className="flex flex-wrap gap-2">
                  {formData.roles.map(role => (
                    <span
                      key={role}
                      className="inline-flex items-center px-3 py-1 rounded-full text-sm bg-primary/10 text-primary"
                    >
                      <Tag className="w-3 h-3 mr-1" />
                      {role}
                      <button
                        type="button"
                        onClick={() => removeRole(role)}
                        className="ml-2 hover:text-red-600"
                      >
                        <X className="w-3 h-3" />
                      </button>
                    </span>
                  ))}
                </div>
              </div>
            )}

            {/* Custom Role */}
            <div className="flex space-x-2">
              <input
                type="text"
                value={customRole}
                onChange={(e) => setCustomRole(e.target.value)}
                onKeyPress={(e) => e.key === 'Enter' && (e.preventDefault(), addCustomRole())}
                className="flex-1 px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent text-sm"
                placeholder="Add custom role..."
              />
              <button
                type="button"
                onClick={addCustomRole}
                disabled={!customRole.trim()}
                className="px-4 py-2 bg-gray-100 text-gray-700 rounded-lg hover:bg-gray-200 transition-colors disabled:opacity-50 text-sm"
              >
                Add
              </button>
            </div>
            <p className="mt-1 text-xs text-gray-500">
              Roles are optional but help with organization. Choose existing or add custom roles.
            </p>
          </div>

          {createMutation.isError && (
            <div className="p-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-600">
              <strong>Failed to register machine.</strong>
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
              disabled={createMutation.isPending}
              className="px-6 py-2 bg-primary text-white rounded-lg hover:bg-blue-600 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {createMutation.isPending ? 'Registering...' : 'Register Machine'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}

export default MachineRegistration
