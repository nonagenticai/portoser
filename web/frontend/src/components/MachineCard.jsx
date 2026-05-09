import React, { useState } from 'react'
import { useDrop } from 'react-dnd'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { Server, HardDrive } from 'lucide-react'
import ServiceCard from './ServiceCard'
import Tooltip from './Tooltip'
import ContextMenu from './ContextMenu'
import { startMachine, stopMachine, restartMachine } from '../api/client'
import clsx from 'clsx'

function MachineCard({ machine, services, healthByService = {}, onServiceMove, isUnassigned = false }) {
  const [contextMenu, setContextMenu] = useState(null)
  const [showInfo, setShowInfo] = useState(false)
  const queryClient = useQueryClient()

  // Machine control mutations
  const startMutation = useMutation({
    mutationFn: () => startMachine(machine.name),
    onSuccess: () => {
      queryClient.invalidateQueries(['services'])
      queryClient.invalidateQueries(['machines'])
    },
  })

  const stopMutation = useMutation({
    mutationFn: () => stopMachine(machine.name),
    onSuccess: () => {
      queryClient.invalidateQueries(['services'])
      queryClient.invalidateQueries(['machines'])
    },
  })

  const restartMutation = useMutation({
    mutationFn: () => restartMachine(machine.name),
    onSuccess: () => {
      queryClient.invalidateQueries(['services'])
      queryClient.invalidateQueries(['machines'])
    },
  })

  const [{ isOver, canDrop }, drop] = useDrop({
    accept: 'SERVICE',
    drop: (item) => {
      onServiceMove(item.service.name, item.service.current_host, machine.name)
    },
    canDrop: (item) => {
      // Can't drop on the same machine
      return item.service.current_host !== machine.name
    },
    collect: (monitor) => ({
      isOver: monitor.isOver(),
      canDrop: monitor.canDrop(),
    }),
  })

  const handleContextMenu = (e) => {
    e.preventDefault()
    e.stopPropagation()

    // Don't show context menu for unassigned section
    if (isUnassigned) return

    const items = [
      {
        label: `Machine Info: ${machine.name}`,
        icon: 'info',
        action: 'info',
      },
      { type: 'divider' },
      {
        label: 'Start All Services',
        icon: 'play',
        action: 'start',
        disabled: startMutation.isPending,
      },
      {
        label: 'Stop All Services',
        icon: 'stop',
        action: 'stop',
        disabled: stopMutation.isPending,
      },
      {
        label: 'Restart All Services',
        icon: 'restart',
        action: 'restart',
        disabled: restartMutation.isPending,
      },
    ]

    setContextMenu({
      x: e.clientX,
      y: e.clientY,
      items,
      onSelect: handleMenuAction,
    })
  }

  const handleMenuAction = (item) => {
    setContextMenu(null)

    switch (item?.action) {
      case 'info':
        setShowInfo(true)
        break
      case 'start':
        startMutation.mutate()
        break
      case 'stop':
        stopMutation.mutate()
        break
      case 'restart':
        restartMutation.mutate()
        break
      default:
        break
    }
  }

  return (
    <>
      {contextMenu && (
        <ContextMenu
          x={contextMenu.x}
          y={contextMenu.y}
          items={contextMenu.items}
          onClose={() => setContextMenu(null)}
          onItemClick={contextMenu.onSelect}
        />
      )}
    <div
      ref={drop}
      onContextMenu={handleContextMenu}
      className={clsx(
        'bg-white rounded-lg border-2 transition-all duration-200',
        {
          'border-gray-200': !isOver,
          'border-primary bg-blue-50': isOver && canDrop,
          'border-red-300 bg-red-50': isOver && !canDrop,
          'opacity-50': isUnassigned,
        }
      )}
    >
      <div className="p-4 border-b border-gray-200">
        <div className="flex items-start justify-between">
          <div className="flex items-center space-x-3">
            <Tooltip
              content={isUnassigned
                ? "Services not assigned to any machine. Drag them to a machine to deploy."
                : `Machine: ${machine.name} at ${machine.ip}. ${machine.roles?.length > 0 ? `Roles: ${machine.roles.join(', ')}` : 'No roles assigned'}`
              }
            >
              <div className={clsx(
                'p-2 rounded-lg cursor-help',
                isUnassigned ? 'bg-gray-100' : 'bg-primary/10'
              )}>
                {isUnassigned ? (
                  <HardDrive className="w-5 h-5 text-gray-500" />
                ) : (
                  <Server className="w-5 h-5 text-primary" />
                )}
              </div>
            </Tooltip>
            <div>
              <h3 className="font-semibold text-gray-900">{machine.name}</h3>
              <Tooltip content="Local network IP address. All services on this machine will be accessible via this IP.">
                <p className="text-sm text-gray-500 cursor-help">{machine.ip}</p>
              </Tooltip>
            </div>
          </div>

          <Tooltip content={`${services.length} ${services.length === 1 ? 'service' : 'services'} currently deployed on this machine`}>
            <div className="text-right cursor-help">
              <div className="text-xs text-gray-500">Services</div>
              <div className="text-lg font-semibold text-gray-900">{services.length}</div>
            </div>
          </Tooltip>
        </div>

        {!isUnassigned && machine.roles?.length > 0 && (
          <div className="mt-3 flex flex-wrap gap-1">
            {machine.roles.map(role => (
              <Tooltip
                key={role}
                content={`Machine role: ${role}. This helps organize services by their primary purpose.`}
              >
                <span className="inline-flex items-center px-2 py-1 rounded text-xs font-medium bg-gray-100 text-gray-700 cursor-help">
                  {role}
                </span>
              </Tooltip>
            ))}
          </div>
        )}
      </div>

      <div className="p-4 space-y-2 min-h-[120px]">
        {services.length === 0 ? (
          <div className="flex items-center justify-center h-24 text-sm text-gray-400">
            {isOver && canDrop ? 'Drop here to deploy' : 'No services'}
          </div>
        ) : (
          services.map(service => (
            <ServiceCard
              key={service.name}
              service={service}
              healthData={healthByService[service.name]}
              isPending={service.pending}
            />
          ))
        )}
      </div>
    </div>
    {showInfo && (
      <div
        className="fixed inset-0 bg-black bg-opacity-40 z-50 flex items-center justify-center p-4"
        onClick={() => setShowInfo(false)}
      >
        <div
          className="bg-white rounded-lg shadow-xl max-w-md w-full p-6"
          onClick={(e) => e.stopPropagation()}
        >
          <div className="flex items-center justify-between mb-4">
            <h3 className="text-lg font-semibold text-gray-900">Machine details</h3>
            <button
              onClick={() => setShowInfo(false)}
              className="text-gray-400 hover:text-gray-600"
              aria-label="Close"
            >
              ×
            </button>
          </div>
          <dl className="grid grid-cols-3 gap-y-2 text-sm">
            <dt className="font-medium text-gray-500">Name</dt>
            <dd className="col-span-2 text-gray-900">{machine.name}</dd>
            <dt className="font-medium text-gray-500">IP</dt>
            <dd className="col-span-2 text-gray-900 font-mono">{machine.ip}</dd>
            <dt className="font-medium text-gray-500">Services</dt>
            <dd className="col-span-2 text-gray-900">{services.length}</dd>
            <dt className="font-medium text-gray-500">Roles</dt>
            <dd className="col-span-2 text-gray-900">
              {machine.roles?.length ? machine.roles.join(', ') : 'None'}
            </dd>
          </dl>
        </div>
      </div>
    )}
    </>
  )
}

export default MachineCard
