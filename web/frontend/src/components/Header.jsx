import React from 'react'
import { Server, Plus, Activity, Heart, Brain, Grid3x3, Shield, Clock, Network, Code, BarChart3, Key, Cpu, LogOut } from 'lucide-react'
import clsx from 'clsx'

function Header({ onAddMachine, onAddService, wsStatus, currentPage = 'cluster', onNavigate, user, onLogout }) {
  const navItems = [
    { id: 'cluster', label: 'Cluster', icon: Grid3x3 },
    { id: 'devices', label: 'Devices', icon: Cpu },
    { id: 'monitoring', label: 'Monitoring', icon: BarChart3 },
    { id: 'health', label: 'Health Dashboard', icon: Heart },
    { id: 'dependencies', label: 'Dependencies', icon: Network },
    { id: 'knowledge', label: 'Knowledge Base', icon: Brain },
    { id: 'vault', label: 'Vault Management', icon: Shield },
    { id: 'certificates', label: 'Certificates', icon: Key },
    { id: 'history', label: 'Deployment History', icon: Clock },
    { id: 'mcp', label: 'MCP Tools', icon: Code },
  ]

  return (
    <header className="bg-white shadow-sm border-b border-gray-200">
      <div className="container mx-auto px-4 py-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center space-x-8">
            {/* Logo */}
            <div className="flex items-center space-x-3">
              <Server className="w-8 h-8 text-primary" />
              <div>
                <h1 className="text-2xl font-bold text-gray-900">Portoser</h1>
                <p className="text-sm text-gray-500">Cluster Management & Deployment</p>
              </div>
            </div>

            {/* Navigation */}
            <nav className="flex items-center space-x-1">
              {navItems.map(item => (
                <button
                  key={item.id}
                  onClick={() => onNavigate && onNavigate(item.id)}
                  className={clsx(
                    'flex items-center space-x-2 px-4 py-2 rounded-lg transition-colors font-medium',
                    {
                      'bg-blue-50 text-blue-700': currentPage === item.id,
                      'text-gray-600 hover:bg-gray-100 hover:text-gray-900': currentPage !== item.id,
                    }
                  )}
                >
                  <item.icon className="w-4 h-4" />
                  <span>{item.label}</span>
                </button>
              ))}
            </nav>
          </div>

          <div className="flex items-center space-x-4">
            <div className="flex items-center space-x-2">
              <Activity className={`w-4 h-4 ${wsStatus === 'connected' ? 'text-success' : 'text-gray-400'}`} />
              <span className="text-sm text-gray-600">
                {wsStatus === 'connected' ? 'Live' : 'Offline'}
              </span>
            </div>

            <button
              onClick={onAddMachine}
              className="flex items-center space-x-2 px-4 py-2 bg-white border border-gray-300 rounded-lg hover:bg-gray-50 transition-colors"
            >
              <Plus className="w-4 h-4" />
              <span>Add Machine</span>
            </button>

            <button
              onClick={onAddService}
              className="flex items-center space-x-2 px-4 py-2 bg-primary text-white rounded-lg hover:bg-blue-600 transition-colors"
            >
              <Plus className="w-4 h-4" />
              <span>Add Service</span>
            </button>

            {onLogout && (
              <div className="flex items-center space-x-2 pl-3 border-l border-gray-200">
                {user?.preferred_username && (
                  <span className="text-sm text-gray-600">{user.preferred_username}</span>
                )}
                <button
                  onClick={onLogout}
                  className="flex items-center space-x-1 px-3 py-2 text-gray-600 hover:bg-gray-100 hover:text-gray-900 rounded-lg transition-colors"
                  title="Sign out"
                  aria-label="Sign out"
                >
                  <LogOut className="w-4 h-4" />
                </button>
              </div>
            )}
          </div>
        </div>
      </div>
    </header>
  )
}

export default Header
