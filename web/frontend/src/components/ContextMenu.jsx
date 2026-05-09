import React, { useEffect, useRef, useState } from 'react'
import {
  Info,
  PlayCircle,
  StopCircle,
  RotateCw,
  Power,
  RefreshCw,
  Trash2,
  XCircle,
  Sparkles,
  Stethoscope,
  Activity
} from 'lucide-react'
import clsx from 'clsx'

const ICONS = {
  info: Info,
  start: PlayCircle,
  play: PlayCircle,
  stop: StopCircle,
  restart: RotateCw,
  rebuild: RefreshCw,
  shutdown: Power,
  down: Trash2,
  up: PlayCircle,
  cancel: XCircle,
  sparkles: Sparkles,
  stethoscope: Stethoscope,
  activity: Activity,
}

function ContextMenu({ x, y, items, onClose, onItemClick }) {
  const menuRef = useRef(null)
  const [position, setPosition] = useState({ x, y })

  useEffect(() => {
    // Adjust position to keep menu on screen
    if (menuRef.current) {
      const rect = menuRef.current.getBoundingClientRect()
      const viewportWidth = window.innerWidth
      const viewportHeight = window.innerHeight

      let adjustedX = x
      let adjustedY = y

      // Adjust horizontal position
      if (x + rect.width > viewportWidth) {
        adjustedX = viewportWidth - rect.width - 10
      }

      // Adjust vertical position
      if (y + rect.height > viewportHeight) {
        adjustedY = viewportHeight - rect.height - 10
      }

      setPosition({ x: adjustedX, y: adjustedY })
    }
  }, [x, y])

  useEffect(() => {
    const handleClickOutside = (e) => {
      if (menuRef.current && !menuRef.current.contains(e.target)) {
        onClose()
      }
    }

    const handleEscape = (e) => {
      if (e.key === 'Escape') {
        onClose()
      }
    }

    document.addEventListener('mousedown', handleClickOutside)
    document.addEventListener('keydown', handleEscape)

    return () => {
      document.removeEventListener('mousedown', handleClickOutside)
      document.removeEventListener('keydown', handleEscape)
    }
  }, [onClose])

  const handleItemClick = (item) => {
    if (!item.disabled) {
      onItemClick(item)
      onClose()
    }
  }

  return (
    <div
      ref={menuRef}
      className="fixed z-50 bg-white rounded-lg shadow-xl border border-gray-200 py-1 min-w-[180px]"
      style={{
        left: `${position.x}px`,
        top: `${position.y}px`,
      }}
    >
      {items.map((item, index) => {
        if (item.type === 'divider') {
          return (
            <div key={index} className="my-1 border-t border-gray-200" />
          )
        }

        const Icon = ICONS[item.icon] || Info

        return (
          <button
            key={index}
            onClick={() => handleItemClick(item)}
            disabled={item.disabled}
            className={clsx(
              'w-full flex items-center space-x-3 px-4 py-2 text-sm transition-colors text-left',
              {
                'text-gray-700 hover:bg-gray-100': !item.danger && !item.disabled,
                'text-red-600 hover:bg-red-50': item.danger && !item.disabled,
                'text-gray-400 cursor-not-allowed': item.disabled,
              }
            )}
          >
            <Icon className="w-4 h-4 flex-shrink-0" />
            <span className="flex-1">{item.label}</span>
            {item.shortcut && (
              <span className="text-xs text-gray-400">{item.shortcut}</span>
            )}
          </button>
        )
      })}
    </div>
  )
}

export default ContextMenu
