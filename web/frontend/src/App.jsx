import React, { useState, useEffect } from 'react'
import { DndProvider } from 'react-dnd'
import { HTML5Backend } from 'react-dnd-html5-backend'
import ClusterView from './components/ClusterView'
import DeploymentPanel from './components/DeploymentPanel'
import Header from './components/Header'
import MachineRegistration from './components/MachineRegistration'
import ServiceRegistration from './components/ServiceRegistration'
import HealthDashboard from './pages/HealthDashboard'
import KnowledgeBase from './pages/KnowledgeBase'
import VaultManagement from './pages/VaultManagement'
import DeploymentHistory from './pages/DeploymentHistory'
import DependenciesGraph from './pages/DependenciesGraph'
import MonitoringDashboard from './pages/MonitoringDashboard'
import MCPDashboard from './components/MCP/MCPDashboard'
import CertificatesPage from './pages/CertificatesPage'
import DeviceList from './components/devices/DeviceList'
import { useWebSocket } from './hooks/useWebSocket'
import { buildAuthedWsUrl } from './api/client'
import { useAuth } from './auth/AuthContext'
import LoginPage from './auth/LoginPage'

function App() {
  const { bootstrapped, bootstrapError, isAuthenticated, authEnabled, logout, user } = useAuth()
  const [currentPage, setCurrentPage] = useState('cluster') // cluster, monitoring, health, knowledge, vault, history, dependencies, mcp, certificates, devices
  const [showMachineModal, setShowMachineModal] = useState(false)
  const [showServiceModal, setShowServiceModal] = useState(false)
  const [pendingMoves, setPendingMoves] = useState([])
  const [deploymentLogs, setDeploymentLogs] = useState([])

  // Don't open the WS until we know who we are: connecting unauthenticated
  // when auth is required just bounces with a 4401 close, then the backoff
  // timer hammers /ws every second.
  const wsUrl = isAuthenticated ? buildAuthedWsUrl('/ws') : null
  const { status: wsStatus, lastMessage } = useWebSocket(wsUrl)

  useEffect(() => {
    if (!lastMessage) return

    let data
    try {
      data = JSON.parse(lastMessage.data)
    } catch (err) {
      // The shared WS endpoint can occasionally emit non-JSON keepalive bytes
      // (or a misbehaving service can broadcast garbage); refuse to crash the
      // whole UI on a single bad frame.
      console.warn('Discarding non-JSON WS message:', err)
      return
    }

    let clearTimer
    switch (data.type) {
      case 'deployment_log':
        setDeploymentLogs(prev => [...prev, data.message])
        break
      case 'deployment_started':
        setDeploymentLogs(['Deployment started...'])
        break
      case 'deployment_completed':
        setDeploymentLogs(prev => [...prev, 'Deployment completed successfully!'])
        clearTimer = setTimeout(() => {
          setPendingMoves([])
          setDeploymentLogs([])
        }, import.meta.env.VITE_DEPLOYMENT_CLEAR_TIMEOUT || 9000)
        break
      case 'deployment_failed':
        setDeploymentLogs(prev => [...prev, `Error: ${data.error || 'Deployment failed'}`])
        break
    }

    return () => {
      if (clearTimer) clearTimeout(clearTimer)
    }
  }, [lastMessage])

  const handleServiceMove = (serviceName, fromMachine, toMachine) => {
    setPendingMoves(prev => {
      // Remove any existing move for this service
      const filtered = prev.filter(m => m.service_name !== serviceName)

      // Only add if actually moving to a different machine
      if (fromMachine !== toMachine) {
        return [...filtered, {
          service_name: serviceName,
          from_machine: fromMachine,
          to_machine: toMachine
        }]
      }

      return filtered
    })
  }

  const handleClearMoves = () => {
    setPendingMoves([])
  }

  // Auth gating: while the public-config probe is in flight we render a
  // splash. If the backend has Keycloak enabled and we have no valid token,
  // route to LoginPage. (When auth is disabled the AuthContext returns
  // isAuthenticated=true unconditionally so this branch never fires.)
  if (!bootstrapped) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gray-50">
        <div className="text-gray-500 text-sm">Loading…</div>
      </div>
    )
  }
  if (bootstrapError) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gray-50 p-4">
        <div className="max-w-md bg-white rounded-md shadow p-6 text-sm text-red-700">
          Failed to reach the backend ({bootstrapError.message}). Refresh once the
          server is up.
        </div>
      </div>
    )
  }
  if (authEnabled && !isAuthenticated) {
    return <LoginPage />
  }

  return (
    <DndProvider backend={HTML5Backend}>
      <div className="min-h-screen bg-gray-50">
        <Header
          onAddMachine={() => setShowMachineModal(true)}
          onAddService={() => setShowServiceModal(true)}
          wsStatus={wsStatus}
          currentPage={currentPage}
          onNavigate={setCurrentPage}
          user={user}
          onLogout={authEnabled ? logout : null}
        />

        {/* Page Content */}
        {currentPage === 'cluster' && (
          <main className="container mx-auto px-4 py-8">
            <ClusterView
              onServiceMove={handleServiceMove}
              pendingMoves={pendingMoves}
            />

            <DeploymentPanel
              pendingMoves={pendingMoves}
              onClearMoves={handleClearMoves}
              deploymentLogs={deploymentLogs}
            />
          </main>
        )}

        {currentPage === 'monitoring' && <MonitoringDashboard />}

        {currentPage === 'health' && <HealthDashboard />}

        {currentPage === 'knowledge' && <KnowledgeBase />}

        {currentPage === 'vault' && <VaultManagement />}

        {currentPage === 'history' && <DeploymentHistory />}

        {currentPage === 'dependencies' && <DependenciesGraph />}

        {currentPage === 'mcp' && <MCPDashboard />}

        {currentPage === 'certificates' && <CertificatesPage />}

        {currentPage === 'devices' && <DeviceList />}

        {/* Modals */}
        {showMachineModal && (
          <MachineRegistration onClose={() => setShowMachineModal(false)} />
        )}

        {showServiceModal && (
          <ServiceRegistration onClose={() => setShowServiceModal(false)} />
        )}
      </div>
    </DndProvider>
  )
}

export default App
