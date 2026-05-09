import React from 'react';
import PropTypes from 'prop-types';
import { AlertTriangle, XCircle, Info, X } from 'lucide-react';
import clsx from 'clsx';

function ErrorAlert({ error, onClose }) {
  if (!error) return null;

  const getIcon = () => {
    switch (error.severity) {
      case 'error':
        return <XCircle className="w-5 h-5" />;
      case 'warning':
        return <AlertTriangle className="w-5 h-5" />;
      case 'info':
        return <Info className="w-5 h-5" />;
      default:
        return <AlertTriangle className="w-5 h-5" />;
    }
  };

  const getColorClasses = () => {
    switch (error.severity) {
      case 'error':
        return 'bg-red-50 border-red-200 text-red-800';
      case 'warning':
        return 'bg-yellow-50 border-yellow-200 text-yellow-800';
      case 'info':
        return 'bg-blue-50 border-blue-200 text-blue-800';
      default:
        return 'bg-red-50 border-red-200 text-red-800';
    }
  };

  const getIconColor = () => {
    switch (error.severity) {
      case 'error':
        return 'text-red-600';
      case 'warning':
        return 'text-yellow-600';
      case 'info':
        return 'text-blue-600';
      default:
        return 'text-red-600';
    }
  };

  return (
    <div className={clsx('rounded-lg border p-4 mb-4', getColorClasses())}>
      <div className="flex items-start gap-3">
        <div className={clsx('flex-shrink-0 mt-0.5', getIconColor())}>
          {getIcon()}
        </div>
        <div className="flex-1">
          <h3 className="font-semibold mb-1">{error.title}</h3>
          <p className="text-sm mb-1">{error.message}</p>
          {error.action && (
            <p className="text-sm font-medium mt-2">{error.action}</p>
          )}
        </div>
        {onClose && (
          <button
            onClick={onClose}
            className="flex-shrink-0 p-1 hover:bg-black hover:bg-opacity-10 rounded transition-colors"
          >
            <X className="w-4 h-4" />
          </button>
        )}
      </div>
    </div>
  );
}

ErrorAlert.propTypes = {
  error: PropTypes.shape({
    title: PropTypes.string.isRequired,
    message: PropTypes.string.isRequired,
    action: PropTypes.string,
    severity: PropTypes.oneOf(['error', 'warning', 'info']),
  }),
  onClose: PropTypes.func,
};

export default ErrorAlert;
