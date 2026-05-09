import React, { useState, useEffect } from 'react'
import {
  Shield, Lock, Key, Server, AlertTriangle, CheckCircle,
  Eye, EyeOff, Plus, RefreshCw, Database, Upload
} from 'lucide-react'
import api from '../api/client'

const VaultManagement = () => {
  const [vaultStatus, setVaultStatus] = useState(null)
  const [services, setServices] = useState([])
  const [selectedService, setSelectedService] = useState(null)
  const [serviceSecrets, setServiceSecrets] = useState([])
  const [loading, setLoading] = useState(true)
  const [showAddSecret, setShowAddSecret] = useState(false)
  const [newSecret, setNewSecret] = useState({ key: '', value: '' })
  const [migrating, setMigrating] = useState(false)

  useEffect(() => {
    loadVaultStatus()
    loadServices()
  }, [])

  useEffect(() => {
    if (selectedService) {
      loadServiceSecrets(selectedService)
    }
  }, [selectedService])

  // All vault calls go through the authenticated client (raw fetch
  // bypassed the Bearer interceptor and 401'd when KEYCLOAK_ENABLED=true).

  const loadVaultStatus = async () => {
    try {
      const { data } = await api.get('/vault/status')
      setVaultStatus(data)
    } catch (error) {
      console.error('Failed to load Vault status:', error)
      setVaultStatus(null)
    }
  }

  const loadServices = async () => {
    try {
      setLoading(true)
      const { data } = await api.get('/vault/services')
      setServices(Array.isArray(data) ? data : [])
    } catch (error) {
      console.error('Failed to load services:', error)
      setServices([])
    } finally {
      setLoading(false)
    }
  }

  const loadServiceSecrets = async (serviceName) => {
    try {
      const { data } = await api.get(`/vault/services/${serviceName}`)
      setServiceSecrets(data.secrets || [])
    } catch (error) {
      console.error('Failed to load service secrets:', error)
      setServiceSecrets([])
    }
  }

  const handleAddSecret = async () => {
    if (!selectedService || !newSecret.key || !newSecret.value) {
      alert('Please fill in all fields')
      return
    }

    try {
      await api.post(`/vault/services/${selectedService}/secrets`, {
        service: selectedService,
        key: newSecret.key,
        value: newSecret.value,
      })
      setNewSecret({ key: '', value: '' })
      setShowAddSecret(false)
      loadServiceSecrets(selectedService)
    } catch (error) {
      alert(`Failed to add secret: ${error.message || error}`)
    }
  }

  const handleMigrateService = async (serviceName) => {
    if (!confirm(`Migrate ${serviceName} .env file to Vault?\n\nThis will:\n- Read the .env file\n- Store secrets in Vault\n- Create a backup of the original`)) {
      return
    }

    try {
      setMigrating(true)
      await api.post('/vault/migrate', { service: serviceName })
      alert(`Successfully migrated ${serviceName} to Vault`)
      loadServices()
      if (selectedService === serviceName) {
        loadServiceSecrets(serviceName)
      }
    } catch (error) {
      alert(`Migration failed: ${error.message || error}`)
    } finally {
      setMigrating(false)
    }
  }

  const handleMigrateAll = async () => {
    if (!confirm('Migrate ALL services to Vault?\n\nThis is a bulk operation that will:\n- Migrate all .env files\n- Create backups\n- May take several minutes')) {
      return
    }

    try {
      setMigrating(true)
      const { data } = await api.post('/vault/migrate-all')
      alert('All services migrated successfully!\n\n' + (data?.output || ''))
      loadServices()
    } catch (error) {
      alert(`Migration failed: ${error.message || error}`)
    } finally {
      setMigrating(false)
    }
  }

  return (
    <div className="min-h-screen bg-gray-50 py-8">
      <div className="container mx-auto px-4">
        {/* Header */}
        <div className="mb-8">
          <div className="flex items-center gap-3 mb-2">
            <Shield className="w-8 h-8 text-blue-600" />
            <h1 className="text-3xl font-bold text-gray-800">Vault Management</h1>
          </div>
          <p className="text-gray-600">Centralized secret management with HashiCorp Vault</p>
        </div>

        {/* Vault Status Card */}
        <div className="bg-white rounded-lg shadow-md p-6 mb-6">
          <div className="flex items-center justify-between mb-4">
            <h2 className="text-xl font-semibold text-gray-800 flex items-center gap-2">
              <Server className="w-5 h-5" />
              Vault Status
            </h2>
            <button
              onClick={loadVaultStatus}
              className="p-2 text-gray-600 hover:bg-gray-100 rounded-lg transition"
            >
              <RefreshCw className="w-5 h-5" />
            </button>
          </div>

          {vaultStatus ? (
            <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
              <div className="flex items-center gap-3">
                <div className={`w-3 h-3 rounded-full ${vaultStatus.healthy ? 'bg-green-500' : 'bg-red-500'}`} />
                <div>
                  <p className="text-sm text-gray-500">Health</p>
                  <p className="font-semibold">{vaultStatus.healthy ? 'Healthy' : 'Unhealthy'}</p>
                </div>
              </div>
              <div className="flex items-center gap-3">
                <CheckCircle className={`w-5 h-5 ${vaultStatus.initialized ? 'text-green-500' : 'text-gray-400'}`} />
                <div>
                  <p className="text-sm text-gray-500">Initialized</p>
                  <p className="font-semibold">{vaultStatus.initialized ? 'Yes' : 'No'}</p>
                </div>
              </div>
              <div className="flex items-center gap-3">
                {vaultStatus.sealed ? (
                  <Lock className="w-5 h-5 text-yellow-500" />
                ) : (
                  <Key className="w-5 h-5 text-green-500" />
                )}
                <div>
                  <p className="text-sm text-gray-500">Sealed</p>
                  <p className="font-semibold">{vaultStatus.sealed ? 'Yes' : 'No'}</p>
                </div>
              </div>
              <div className="flex items-center gap-3">
                <Server className="w-5 h-5 text-blue-500" />
                <div>
                  <p className="text-sm text-gray-500">Address</p>
                  <p className="font-semibold text-sm">{vaultStatus.address}</p>
                </div>
              </div>
            </div>
          ) : (
            <p className="text-gray-500">Loading status...</p>
          )}

          {vaultStatus?.sealed && (
            <div className="mt-4 p-4 bg-yellow-50 border border-yellow-200 rounded-lg flex items-start gap-3">
              <AlertTriangle className="w-5 h-5 text-yellow-600 mt-0.5" />
              <div>
                <p className="font-semibold text-yellow-800">Vault is Sealed</p>
                <p className="text-sm text-yellow-700 mt-1">
                  Run <code className="bg-yellow-100 px-2 py-0.5 rounded">portoser vault unseal</code> to unseal it.
                </p>
              </div>
            </div>
          )}
        </div>

        {/* Main Content Grid */}
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          {/* Services List */}
          <div className="bg-white rounded-lg shadow-md p-6">
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-xl font-semibold text-gray-800 flex items-center gap-2">
                <Database className="w-5 h-5" />
                Services
              </h2>
              <button
                onClick={handleMigrateAll}
                disabled={migrating}
                className="flex items-center gap-2 px-3 py-1.5 bg-blue-600 text-white text-sm rounded-lg hover:bg-blue-700 transition disabled:opacity-50"
              >
                <Upload className="w-4 h-4" />
                Migrate All
              </button>
            </div>

            {loading ? (
              <p className="text-gray-500">Loading services...</p>
            ) : services.length === 0 ? (
              <div className="text-center py-8">
                <Database className="w-12 h-12 text-gray-300 mx-auto mb-3" />
                <p className="text-gray-500 mb-2">No services in Vault</p>
                <p className="text-sm text-gray-400">Migrate .env files to get started</p>
              </div>
            ) : (
              <div className="space-y-2">
                {services.map(service => (
                  <div
                    key={service.service}
                    onClick={() => setSelectedService(service.service)}
                    className={`p-3 rounded-lg cursor-pointer transition ${
                      selectedService === service.service
                        ? 'bg-blue-50 border-2 border-blue-500'
                        : 'bg-gray-50 border-2 border-transparent hover:bg-gray-100'
                    }`}
                  >
                    <p className="font-semibold text-gray-800">{service.service}</p>
                    <p className="text-sm text-gray-500">
                      {service.secret_count > 0 ? `${service.secret_count} secrets` : 'Encrypted'}
                    </p>
                  </div>
                ))}
              </div>
            )}
          </div>

          {/* Secret Details */}
          <div className="lg:col-span-2 bg-white rounded-lg shadow-md p-6">
            {selectedService ? (
              <>
                <div className="flex items-center justify-between mb-4">
                  <h2 className="text-xl font-semibold text-gray-800 flex items-center gap-2">
                    <Key className="w-5 h-5" />
                    Secrets for {selectedService}
                  </h2>
                  <div className="flex gap-2">
                    <button
                      onClick={() => handleMigrateService(selectedService)}
                      disabled={migrating}
                      className="flex items-center gap-2 px-3 py-1.5 bg-green-600 text-white text-sm rounded-lg hover:bg-green-700 transition disabled:opacity-50"
                    >
                      <Upload className="w-4 h-4" />
                      Migrate
                    </button>
                    <button
                      onClick={() => setShowAddSecret(true)}
                      className="flex items-center gap-2 px-3 py-1.5 bg-blue-600 text-white text-sm rounded-lg hover:bg-blue-700 transition"
                    >
                      <Plus className="w-4 h-4" />
                      Add Secret
                    </button>
                  </div>
                </div>

                {/* Secrets List */}
                {serviceSecrets.length === 0 ? (
                  <div className="text-center py-8">
                    <Key className="w-12 h-12 text-gray-300 mx-auto mb-3" />
                    <p className="text-gray-500">No secrets found</p>
                  </div>
                ) : (
                  <div className="space-y-2">
                    {serviceSecrets.map(secret => (
                      <div
                        key={secret.key}
                        className="p-4 bg-gray-50 rounded-lg border border-gray-200"
                      >
                        <div className="flex items-center justify-between">
                          <div className="flex-1">
                            <p className="font-mono font-semibold text-gray-800">{secret.key}</p>
                            <div className="flex items-center gap-2 mt-1">
                              <code className="text-sm text-gray-500 bg-white px-2 py-1 rounded border">
                                {secret.value_preview}
                              </code>
                              <Lock className="w-4 h-4 text-gray-400" title="Value encrypted in Vault" />
                            </div>
                          </div>
                          {secret.has_value && (
                            <CheckCircle className="w-5 h-5 text-green-500" title="Has value" />
                          )}
                        </div>
                      </div>
                    ))}
                  </div>
                )}

                {/* Add Secret Form */}
                {showAddSecret && (
                  <div className="mt-6 p-4 bg-blue-50 rounded-lg border border-blue-200">
                    <h3 className="font-semibold text-gray-800 mb-3">Add New Secret</h3>
                    <div className="space-y-3">
                      <div>
                        <label className="block text-sm font-medium text-gray-700 mb-1">
                          Key (UPPERCASE_WITH_UNDERSCORES)
                        </label>
                        <input
                          type="text"
                          value={newSecret.key}
                          onChange={(e) => setNewSecret({ ...newSecret, key: e.target.value.toUpperCase() })}
                          placeholder="DATABASE_URL"
                          className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent font-mono"
                        />
                      </div>
                      <div>
                        <label className="block text-sm font-medium text-gray-700 mb-1">
                          Value
                        </label>
                        <textarea
                          value={newSecret.value}
                          onChange={(e) => setNewSecret({ ...newSecret, value: e.target.value })}
                          placeholder="secret value..."
                          rows={3}
                          className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent font-mono text-sm"
                        />
                      </div>
                      <div className="flex gap-2 justify-end">
                        <button
                          onClick={() => {
                            setShowAddSecret(false)
                            setNewSecret({ key: '', value: '' })
                          }}
                          className="px-4 py-2 text-gray-700 bg-gray-200 rounded-lg hover:bg-gray-300 transition"
                        >
                          Cancel
                        </button>
                        <button
                          onClick={handleAddSecret}
                          className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition"
                        >
                          Add Secret
                        </button>
                      </div>
                    </div>
                  </div>
                )}
              </>
            ) : (
              <div className="text-center py-12">
                <Shield className="w-16 h-16 text-gray-300 mx-auto mb-4" />
                <p className="text-gray-500 text-lg">Select a service to view secrets</p>
                <p className="text-sm text-gray-400 mt-2">
                  Secret values are encrypted and never fully displayed for security
                </p>
              </div>
            )}
          </div>
        </div>

        {/* Security Notice */}
        <div className="mt-6 p-4 bg-blue-50 border border-blue-200 rounded-lg">
          <div className="flex items-start gap-3">
            <Shield className="w-5 h-5 text-blue-600 mt-0.5" />
            <div>
              <p className="font-semibold text-blue-800">Security Notice</p>
              <ul className="text-sm text-blue-700 mt-2 space-y-1">
                <li>• Secret values are masked for security (only preview shown)</li>
                <li>• All operations are audit logged with your user information</li>
                <li>• Secrets are encrypted at rest in Vault</li>
                <li>• Only authenticated users can access this page</li>
              </ul>
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}

export default VaultManagement
