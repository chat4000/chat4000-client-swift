import { useState } from 'react';

interface SetupScreenProps {
  onConnect: (server: string, port: string, token: string) => void;
}

export function SetupScreen({ onConnect }: SetupScreenProps) {
  const [server, setServer] = useState('');
  const [port, setPort] = useState('');
  const [token, setToken] = useState('');
  const [error, setError] = useState('');
  const [isConnecting, setIsConnecting] = useState(false);

  const handleConnect = async () => {
    setError('');

    if (!server || !port || !token) {
      setError('Please fill in all fields');
      return;
    }

    setIsConnecting(true);

    // Simulate connection attempt
    setTimeout(() => {
      setIsConnecting(false);
      // For demo purposes, we'll accept any input
      onConnect(server, port, token);
    }, 1000);
  };

  return (
    <div className="size-full flex items-center justify-center" style={{ backgroundColor: '#0F0F0F' }}>
      <div className="w-full max-w-md px-6">
        <div
          className="rounded-2xl p-8 space-y-6"
          style={{
            backgroundColor: '#141414',
            border: '1px solid #1E1E1E'
          }}
        >
          {/* App Icon */}
          <div className="flex justify-center mb-2">
            <svg width="64" height="64" viewBox="0 0 64 64" fill="none" xmlns="http://www.w3.org/2000/svg">
              <path
                d="M16 32C16 32 20 28 24 28C28 28 32 32 32 32C32 32 36 28 40 28C44 28 48 32 48 32M16 32V40C16 42.2091 17.7909 44 20 44H44C46.2091 44 48 42.2091 48 40V32M24 20L28 24L32 20M40 20L36 24L32 20"
                stroke="#E0E0E0"
                strokeWidth="2.5"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </svg>
          </div>

          {/* Title */}
          <div className="text-center">
            <h1 className="text-white mb-1" style={{ fontSize: '28px', fontWeight: '700' }}>chat4000</h1>
            <p className="text-gray-400" style={{ fontSize: '14px' }}>Connect to your AI agent</p>
          </div>

          {/* Input Fields */}
          <div className="space-y-4">
            <div>
              <label className="block text-gray-300 mb-2" style={{ fontSize: '14px' }}>Server</label>
              <input
                type="text"
                value={server}
                onChange={(e) => setServer(e.target.value)}
                placeholder="agent.example.com"
                className="w-full px-4 py-3 rounded-lg outline-none transition-colors duration-200"
                style={{
                  backgroundColor: '#1E1E1E',
                  border: '1px solid #2A2A2A',
                  color: '#ffffff',
                }}
                onFocus={(e) => e.target.style.borderColor = '#505050'}
                onBlur={(e) => e.target.style.borderColor = '#2A2A2A'}
              />
            </div>

            <div>
              <label className="block text-gray-300 mb-2" style={{ fontSize: '14px' }}>Port</label>
              <input
                type="text"
                value={port}
                onChange={(e) => setPort(e.target.value)}
                placeholder="18789"
                className="w-full px-4 py-3 rounded-lg outline-none transition-colors duration-200"
                style={{
                  backgroundColor: '#1E1E1E',
                  border: '1px solid #2A2A2A',
                  color: '#ffffff',
                }}
                onFocus={(e) => e.target.style.borderColor = '#505050'}
                onBlur={(e) => e.target.style.borderColor = '#2A2A2A'}
              />
            </div>

            <div>
              <label className="block text-gray-300 mb-2" style={{ fontSize: '14px' }}>Token</label>
              <input
                type="password"
                value={token}
                onChange={(e) => setToken(e.target.value)}
                placeholder="oc_tok_..."
                className="w-full px-4 py-3 rounded-lg outline-none transition-colors duration-200"
                style={{
                  backgroundColor: '#1E1E1E',
                  border: '1px solid #2A2A2A',
                  color: '#ffffff',
                }}
                onFocus={(e) => e.target.style.borderColor = '#505050'}
                onBlur={(e) => e.target.style.borderColor = '#2A2A2A'}
              />
            </div>
          </div>

          {/* Connect Button */}
          <button
            onClick={handleConnect}
            disabled={isConnecting}
            className="w-full py-3 rounded-lg transition-all duration-200 hover:opacity-90 disabled:opacity-50"
            style={{
              backgroundColor: '#ffffff',
              color: '#0F0F0F',
            }}
          >
            {isConnecting ? 'Connecting...' : 'Connect'}
          </button>

          {/* Error Message */}
          {error && (
            <div
              className="text-center py-2 px-3 rounded-lg"
              style={{
                fontSize: '13px',
                color: '#FF4A4A',
                backgroundColor: 'rgba(255, 74, 74, 0.1)'
              }}
            >
              {error}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
