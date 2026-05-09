import React, { useState } from 'react'
import { HelpCircle } from 'lucide-react'
import clsx from 'clsx'

function Tooltip({ content, children, position = 'top' }) {
  const [isVisible, setIsVisible] = useState(false)

  const positionClasses = {
    top: 'bottom-full left-1/2 -translate-x-1/2 mb-2',
    bottom: 'top-full left-1/2 -translate-x-1/2 mt-2',
    left: 'right-full top-1/2 -translate-y-1/2 mr-2',
    right: 'left-full top-1/2 -translate-y-1/2 ml-2',
  }

  return (
    <div className="relative inline-block">
      <div
        onMouseEnter={() => setIsVisible(true)}
        onMouseLeave={() => setIsVisible(false)}
        onClick={() => setIsVisible(!isVisible)}
      >
        {children}
      </div>

      {isVisible && (
        <div
          className={clsx(
            'absolute z-50 px-3 py-2 text-sm text-white bg-gray-900 rounded-lg shadow-lg',
            'max-w-xs whitespace-normal',
            positionClasses[position]
          )}
          style={{ minWidth: '200px' }}
        >
          {content}
          <div
            className={clsx(
              'absolute w-2 h-2 bg-gray-900 transform rotate-45',
              {
                'top-full left-1/2 -translate-x-1/2 -mt-1': position === 'top',
                'bottom-full left-1/2 -translate-x-1/2 -mb-1': position === 'bottom',
                'top-1/2 left-full -translate-y-1/2 -ml-1': position === 'left',
                'top-1/2 right-full -translate-y-1/2 -mr-1': position === 'right',
              }
            )}
          />
        </div>
      )}
    </div>
  )
}

export function InfoIcon({ content, position = 'top' }) {
  return (
    <Tooltip content={content} position={position}>
      <HelpCircle className="w-4 h-4 text-gray-400 hover:text-gray-600 cursor-help" />
    </Tooltip>
  )
}

export default Tooltip
