import { useState } from 'react';

export function useErrorHandler() {
  const [error, setError] = useState(null);

  const handleError = (err) => {
    if (err.status === 404) {
      setError({
        title: "Not Found",
        message: "The requested resource was not found.",
        action: "Please check the URL or try again.",
        severity: "warning"
      });
    } else if (err.status === 401) {
      setError({
        title: "Authentication Required",
        message: "You need to log in to access this resource.",
        action: "Please log in and try again.",
        severity: "error"
      });
    } else if (err.status === 403) {
      setError({
        title: "Access Denied",
        message: "You don't have permission to access this resource.",
        action: "Contact your administrator if you need access.",
        severity: "error"
      });
    } else if (err.status === 500) {
      setError({
        title: "Server Error",
        message: "Something went wrong on the server.",
        action: "Please try again later or contact support.",
        severity: "error"
      });
    } else if (err.status === 503) {
      setError({
        title: "Service Unavailable",
        message: "The service is temporarily unavailable.",
        action: "Please try again in a few moments.",
        severity: "error"
      });
    } else if (err.isNetworkError) {
      setError({
        title: "Network Error",
        message: "Unable to connect to the server.",
        action: "Check your internet connection and try again.",
        severity: "error"
      });
    } else {
      setError({
        title: "Error",
        message: err.message || "An unexpected error occurred.",
        action: "Please try again.",
        severity: "error"
      });
    }
  };

  const clearError = () => setError(null);

  return { error, handleError, clearError };
}
