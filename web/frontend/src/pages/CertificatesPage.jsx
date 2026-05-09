import React, { useState, useEffect } from 'react'
import {
  Shield, Key, Server, CheckCircle, XCircle, AlertTriangle,
  Download, Upload, RefreshCw, Copy, Globe, Lock
} from 'lucide-react'
import {
  checkBrowserCerts,
  installBrowserCerts,
  uninstallBrowserCerts,
  copyKeycloakCA,
  validateServiceCerts,
  generateCertificates,
  generateServerCertificates,
  fetchServices
} from '../api/client'

const CertificatesPage = () => {
  const [activeTab, setActiveTab] = useState('browser') // browser, validation, operations
  const [browserStatus, setBrowserStatus] = useState(null)
  const [services, setServices] = useState([])
  const [selectedService, setSelectedService] = useState(null)
  const [validation, setValidation] = useState(null)
  const [loading, setLoading] = useState(false)
  const [output, setOutput] = useState(null)

  useEffect(() => {
    loadServices()
    loadBrowserStatus()
  }, [])

  const loadServices = async () => {
    try {
      const data = await fetchServices()
      setServices(data)
    } catch (error) {
      console.error('Failed to load services:', error)
    }
  }

  const loadBrowserStatus = async () => {
    try {
      setLoading(true)
      const data = await checkBrowserCerts()
      setBrowserStatus(data)
    } catch (error) {
      console.error('Failed to load browser status:', error)
    } finally {
      setLoading(false)
    }
  }

  const handleInstallBrowserCerts = async (service = null) => {
    if (!confirm(`Install ${service || 'all'} CA certificate(s) to System Keychain?\n\nYou will be prompted for your macOS password.`)) {
      return
    }

    try {
      setLoading(true)
      const data = await installBrowserCerts(service)

      setOutput(data.output)
      loadBrowserStatus()

      if (data.success) {
        alert('Certificate installation complete! You may need to restart your browser.')
      } else {
        alert(`Installation failed: ${data.error || 'Unknown error'}`)
      }
    } catch (error) {
      alert(`Error: ${error.message}`)
    } finally {
      setLoading(false)
    }
  }

  const handleValidateService = async (service) => {
    try {
      setLoading(true)
      setSelectedService(service)

      const data = await validateServiceCerts(service)

      setValidation(data)
      setActiveTab('validation')
    } catch (error) {
      alert(`Validation failed: ${error.message}`)
    } finally {
      setLoading(false)
    }
  }

  const handleGenerateClientCert = async (service) => {
    if (!confirm(`Generate PostgreSQL client certificate for ${service}?`)) {
      return
    }

    try {
      setLoading(true)
      const data = await generateCertificates(service)

      setOutput(data.output)

      if (data.success) {
        alert('Client certificate generated successfully!')
      } else {
        alert(`Generation failed: ${data.error}`)
      }
    } catch (error) {
      alert(`Error: ${error.message}`)
    } finally {
      setLoading(false)
    }
  }

  const handleGenerateServerCert = async (service) => {
    if (!confirm(`Generate HTTPS server certificate for ${service}?`)) {
      return
    }

    try {
      setLoading(true)
      const data = await generateServerCertificates(service)

      setOutput(data.output)

      if (data.success) {
        alert('Server certificate generated successfully!')
      } else {
        alert(`Generation failed: ${data.error}`)
      }
    } catch (error) {
      alert(`Error: ${error.message}`)
    } finally {
      setLoading(false)
    }
  }

  const handleCopyKeycloakCA = async (service) => {
    if (!confirm(`Copy Keycloak CA certificate to ${service}?`)) {
      return
    }

    try {
      setLoading(true)
      const data = await copyKeycloakCA(service)

      setOutput(data.output)

      if (data.success) {
        alert('Keycloak CA copied successfully!')
        handleValidateService(service)
      } else {
        alert(`Copy failed: ${data.error}`)
      }
    } catch (error) {
      alert(`Error: ${error.message}`)
    } finally {
      setLoading(false)
    }
  }

  const renderBrowserTab = () => (
    <div className="space-y-6">
      {/* Browser Status Card */}
      <div className="bg-white rounded-lg shadow-md p-6">
        <div className="flex items-center justify-between mb-4">
          <div className="flex items-center space-x-3">
            <Globe className="w-6 h-6 text-blue-600" />
            <h2 className="text-xl font-bold">Browser Certificate Status</h2>
          </div>
          <button
            onClick={() => loadBrowserStatus()}
            disabled={loading}
            className="p-2 hover:bg-gray-100 rounded-lg transition-colors"
          >
            <RefreshCw className={`w-5 h-5 ${loading ? 'animate-spin' : ''}`} />
          </button>
        </div>

        {browserStatus && (
          <div className="grid grid-cols-3 gap-4 mb-6">
            <div className="bg-green-50 rounded-lg p-4">
              <div className="text-3xl font-bold text-green-600">{browserStatus.installed}</div>
              <div className="text-sm text-gray-600">Installed</div>
            </div>
            <div className="bg-red-50 rounded-lg p-4">
              <div className="text-3xl font-bold text-red-600">{browserStatus.missing}</div>
              <div className="text-sm text-gray-600">Missing</div>
            </div>
            <div className="bg-blue-50 rounded-lg p-4">
              <div className="text-3xl font-bold text-blue-600">{browserStatus.total}</div>
              <div className="text-sm text-gray-600">Total</div>
            </div>
          </div>
        )}

        <div className="flex space-x-4">
          <button
            onClick={() => handleInstallBrowserCerts()}
            disabled={loading || (browserStatus && browserStatus.all_installed)}
            className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:bg-gray-300 disabled:cursor-not-allowed transition-colors flex items-center space-x-2"
          >
            <Download className="w-4 h-4" />
            <span>Install All Missing Certificates</span>
          </button>
        </div>

        {browserStatus && browserStatus.all_installed && (
          <div className="mt-4 p-4 bg-green-50 rounded-lg flex items-center space-x-2">
            <CheckCircle className="w-5 h-5 text-green-600" />
            <span className="text-green-800 font-medium">All certificates are installed!</span>
          </div>
        )}
      </div>

      {/* Output */}
      {output && (
        <div className="bg-gray-900 text-gray-100 rounded-lg p-4 font-mono text-sm overflow-x-auto">
          <pre className="whitespace-pre-wrap">{output}</pre>
        </div>
      )}
    </div>
  )

  const renderValidationTab = () => (
    <div className="space-y-6">
      {/* Service Selector */}
      <div className="bg-white rounded-lg shadow-md p-6">
        <div className="flex items-center space-x-3 mb-4">
          <Shield className="w-6 h-6 text-blue-600" />
          <h2 className="text-xl font-bold">Certificate Validation</h2>
        </div>

        <div className="flex space-x-4 items-end">
          <div className="flex-1">
            <label className="block text-sm font-medium text-gray-700 mb-2">
              Select Service
            </label>
            <select
              value={selectedService || ''}
              onChange={(e) => setSelectedService(e.target.value)}
              className="w-full border border-gray-300 rounded-lg px-3 py-2"
            >
              <option value="">-- Choose a service --</option>
              {services.map(service => (
                <option key={service.name} value={service.name}>
                  {service.name}
                </option>
              ))}
            </select>
          </div>
          <button
            onClick={() => selectedService && handleValidateService(selectedService)}
            disabled={!selectedService || loading}
            className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:bg-gray-300 disabled:cursor-not-allowed transition-colors flex items-center space-x-2"
          >
            <CheckCircle className="w-4 h-4" />
            <span>Validate</span>
          </button>
        </div>
      </div>

      {/* Validation Results */}
      {validation && (
        <div className="bg-white rounded-lg shadow-md p-6">
          <div className="flex items-center justify-between mb-4">
            <h3 className="text-lg font-bold">Validation Results: {validation.service}</h3>
            {validation.valid ? (
              <CheckCircle className="w-6 h-6 text-green-600" />
            ) : (
              <XCircle className="w-6 h-6 text-red-600" />
            )}
          </div>

          {validation.valid ? (
            <div className="p-4 bg-green-50 rounded-lg">
              <div className="text-green-800 font-medium">
                ✓ All certificates are valid
              </div>
            </div>
          ) : (
            <div className="space-y-4">
              <div className="p-4 bg-red-50 rounded-lg">
                <div className="text-red-800 font-medium mb-2">
                  ✗ Missing Certificates:
                </div>
                <ul className="list-disc list-inside space-y-1">
                  {validation.missing_certificates.map((cert, idx) => (
                    <li key={idx} className="text-red-700">{cert}</li>
                  ))}
                </ul>
              </div>

              <div className="p-4 bg-blue-50 rounded-lg">
                <div className="text-blue-800 font-medium mb-2">
                  💡 Recommended Actions:
                </div>
                <ul className="list-disc list-inside space-y-1">
                  {validation.recommendations.map((rec, idx) => (
                    <li key={idx} className="text-blue-700 text-sm">{rec}</li>
                  ))}
                </ul>
              </div>
            </div>
          )}

          {validation.output && (
            <details className="mt-4">
              <summary className="cursor-pointer text-sm text-gray-600 hover:text-gray-800">
                Show detailed output
              </summary>
              <div className="mt-2 bg-gray-900 text-gray-100 rounded-lg p-4 font-mono text-sm overflow-x-auto">
                <pre className="whitespace-pre-wrap">{validation.output}</pre>
              </div>
            </details>
          )}
        </div>
      )}
    </div>
  )

  const renderOperationsTab = () => (
    <div className="space-y-6">
      {/* Operations */}
      <div className="bg-white rounded-lg shadow-md p-6">
        <div className="flex items-center space-x-3 mb-6">
          <Key className="w-6 h-6 text-blue-600" />
          <h2 className="text-xl font-bold">Certificate Operations</h2>
        </div>

        {/* Service Selector */}
        <div className="mb-6">
          <label className="block text-sm font-medium text-gray-700 mb-2">
            Select Service
          </label>
          <select
            value={selectedService || ''}
            onChange={(e) => setSelectedService(e.target.value)}
            className="w-full border border-gray-300 rounded-lg px-3 py-2"
          >
            <option value="">-- Choose a service --</option>
            {services.map(service => (
              <option key={service.name} value={service.name}>
                {service.name}
              </option>
            ))}
          </select>
        </div>

        {/* Operation Buttons */}
        {selectedService && (
          <div className="grid grid-cols-2 gap-4">
            <button
              onClick={() => handleGenerateClientCert(selectedService)}
              disabled={loading}
              className="p-4 border-2 border-blue-300 rounded-lg hover:bg-blue-50 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              <Lock className="w-6 h-6 text-blue-600 mb-2" />
              <div className="font-medium">Generate Client Certificate</div>
              <div className="text-sm text-gray-600">PostgreSQL mTLS certificate</div>
            </button>

            <button
              onClick={() => handleGenerateServerCert(selectedService)}
              disabled={loading}
              className="p-4 border-2 border-green-300 rounded-lg hover:bg-green-50 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              <Server className="w-6 h-6 text-green-600 mb-2" />
              <div className="font-medium">Generate Server Certificate</div>
              <div className="text-sm text-gray-600">HTTPS server certificate (Caddy)</div>
            </button>

            <button
              onClick={() => handleCopyKeycloakCA(selectedService)}
              disabled={loading}
              className="p-4 border-2 border-purple-300 rounded-lg hover:bg-purple-50 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              <Copy className="w-6 h-6 text-purple-600 mb-2" />
              <div className="font-medium">Copy Keycloak CA</div>
              <div className="text-sm text-gray-600">For Keycloak authentication</div>
            </button>

            <button
              onClick={() => handleValidateService(selectedService)}
              disabled={loading}
              className="p-4 border-2 border-yellow-300 rounded-lg hover:bg-yellow-50 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              <CheckCircle className="w-6 h-6 text-yellow-600 mb-2" />
              <div className="font-medium">Validate Certificates</div>
              <div className="text-sm text-gray-600">Check all required certificates</div>
            </button>
          </div>
        )}
      </div>

      {/* Output */}
      {output && (
        <div className="bg-gray-900 text-gray-100 rounded-lg p-4 font-mono text-sm overflow-x-auto">
          <pre className="whitespace-pre-wrap">{output}</pre>
        </div>
      )}
    </div>
  )

  return (
    <div className="min-h-screen bg-gray-50 py-8">
      <div className="container mx-auto px-4 max-w-6xl">
        {/* Header */}
        <div className="mb-8">
          <h1 className="text-3xl font-bold text-gray-900 mb-2">Certificate Management</h1>
          <p className="text-gray-600">
            Manage SSL/TLS certificates for services, browsers, and Caddy reverse proxy
          </p>
        </div>

        {/* Tabs */}
        <div className="bg-white rounded-lg shadow-md mb-6">
          <div className="flex border-b">
            <button
              onClick={() => setActiveTab('browser')}
              className={`px-6 py-3 font-medium transition-colors ${
                activeTab === 'browser'
                  ? 'border-b-2 border-blue-600 text-blue-600'
                  : 'text-gray-600 hover:text-gray-900'
              }`}
            >
              <div className="flex items-center space-x-2">
                <Globe className="w-4 h-4" />
                <span>Browser Certificates</span>
              </div>
            </button>
            <button
              onClick={() => setActiveTab('validation')}
              className={`px-6 py-3 font-medium transition-colors ${
                activeTab === 'validation'
                  ? 'border-b-2 border-blue-600 text-blue-600'
                  : 'text-gray-600 hover:text-gray-900'
              }`}
            >
              <div className="flex items-center space-x-2">
                <Shield className="w-4 h-4" />
                <span>Validation</span>
              </div>
            </button>
            <button
              onClick={() => setActiveTab('operations')}
              className={`px-6 py-3 font-medium transition-colors ${
                activeTab === 'operations'
                  ? 'border-b-2 border-blue-600 text-blue-600'
                  : 'text-gray-600 hover:text-gray-900'
              }`}
            >
              <div className="flex items-center space-x-2">
                <Key className="w-4 h-4" />
                <span>Operations</span>
              </div>
            </button>
          </div>
        </div>

        {/* Tab Content */}
        <div>
          {activeTab === 'browser' && renderBrowserTab()}
          {activeTab === 'validation' && renderValidationTab()}
          {activeTab === 'operations' && renderOperationsTab()}
        </div>
      </div>
    </div>
  )
}

export default CertificatesPage
