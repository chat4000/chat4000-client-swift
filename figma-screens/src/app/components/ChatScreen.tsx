import { useState, useRef, useEffect } from 'react';
import { Settings, Send } from 'lucide-react';

interface Message {
  id: string;
  text: string;
  sender: 'user' | 'agent';
  timestamp: Date;
}

interface ChatScreenProps {
  server: string;
  port: string;
  onOpenSettings: () => void;
}

export function ChatScreen({ server, port, onOpenSettings }: ChatScreenProps) {
  const [messages, setMessages] = useState<Message[]>([
    {
      id: '1',
      text: 'Hello! I\'m your AI assistant. How can I help you today?',
      sender: 'agent',
      timestamp: new Date()
    }
  ]);
  const [inputValue, setInputValue] = useState('');
  const [connectionStatus, setConnectionStatus] = useState<'connected' | 'reconnecting' | 'disconnected'>('connected');
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    scrollToBottom();
  }, [messages]);

  const scrollToBottom = () => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  };

  const handleSend = () => {
    if (!inputValue.trim()) return;

    const userMessage: Message = {
      id: Date.now().toString(),
      text: inputValue,
      sender: 'user',
      timestamp: new Date()
    };

    setMessages((prev) => [...prev, userMessage]);
    setInputValue('');

    // Simulate agent response
    setTimeout(() => {
      const agentMessage: Message = {
        id: (Date.now() + 1).toString(),
        text: 'I received your message. This is a demo response from the AI agent.',
        sender: 'agent',
        timestamp: new Date()
      };
      setMessages((prev) => [...prev, agentMessage]);
    }, 1000);
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      handleSend();
    }
  };

  const formatTime = (date: Date) => {
    return date.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
  };

  const getStatusColor = () => {
    switch (connectionStatus) {
      case 'connected':
        return '#10B981';
      case 'reconnecting':
        return '#F59E0B';
      case 'disconnected':
        return '#EF4444';
    }
  };

  return (
    <div className="size-full flex flex-col" style={{ backgroundColor: '#0F0F0F' }}>
      {/* Top Nav Bar */}
      <div
        className="flex items-center justify-between px-6 py-4"
        style={{
          borderBottom: '1px solid #1E1E1E'
        }}
      >
        <h2 className="text-white">chat4000</h2>
        <div className="flex items-center gap-3">
          <div
            className="w-2.5 h-2.5 rounded-full"
            style={{ backgroundColor: getStatusColor() }}
            title={connectionStatus}
          />
          <button
            onClick={onOpenSettings}
            className="p-2 rounded-lg hover:bg-opacity-10 transition-colors duration-200"
            style={{ color: '#9CA3AF' }}
            onMouseEnter={(e) => e.currentTarget.style.backgroundColor = 'rgba(255, 255, 255, 0.05)'}
            onMouseLeave={(e) => e.currentTarget.style.backgroundColor = 'transparent'}
          >
            <Settings size={20} />
          </button>
        </div>
      </div>

      {/* Message Area */}
      <div className="flex-1 overflow-y-auto px-6 py-6 space-y-6">
        {messages.map((message, index) => {
          const prevMessage = messages[index - 1];
          const isNewGroup = !prevMessage || prevMessage.sender !== message.sender;

          return (
            <div key={message.id} className={`flex ${message.sender === 'user' ? 'justify-end' : 'justify-start'}`}>
              <div className={`flex gap-3 max-w-[70%] ${message.sender === 'user' ? 'flex-row-reverse' : 'flex-row'}`}>
                {/* Agent Icon */}
                {message.sender === 'agent' && isNewGroup && (
                  <div
                    className="w-8 h-8 rounded-full flex items-center justify-center flex-shrink-0"
                    style={{ backgroundColor: '#1A1A1A' }}
                  >
                    <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                      <path
                        d="M4 8C4 8 5 7 6 7C7 7 8 8 8 8C8 8 9 7 10 7C11 7 12 8 12 8M4 8V10C4 10.5523 4.44772 11 5 11H11C11.5523 11 12 10.5523 12 10V8M6 5L7 6L8 5M10 5L9 6L8 5"
                        stroke="#9CA3AF"
                        strokeWidth="1.2"
                        strokeLinecap="round"
                        strokeLinejoin="round"
                      />
                    </svg>
                  </div>
                )}

                <div className="flex flex-col gap-1">
                  {/* Message Bubble */}
                  <div
                    className="px-4 py-3 rounded-2xl"
                    style={{
                      backgroundColor: message.sender === 'user' ? '#ffffff' : '#1A1A1A',
                      color: message.sender === 'user' ? '#0F0F0F' : '#E0E0E0',
                      borderRadius: message.sender === 'user'
                        ? '18px 18px 4px 18px'
                        : '18px 18px 18px 4px',
                      boxShadow: '0 2px 8px rgba(0, 0, 0, 0.2)'
                    }}
                  >
                    <p style={{ fontSize: '15px', lineHeight: '1.5', whiteSpace: 'pre-wrap' }}>
                      {message.text}
                    </p>
                  </div>

                  {/* Timestamp */}
                  <div
                    className={`px-1 ${message.sender === 'user' ? 'text-right' : 'text-left'}`}
                    style={{
                      fontSize: '11px',
                      color: '#666666'
                    }}
                  >
                    {formatTime(message.timestamp)}
                  </div>
                </div>
              </div>
            </div>
          );
        })}
        <div ref={messagesEndRef} />
      </div>

      {/* Input Area */}
      <div
        className="px-6 py-4"
        style={{
          backgroundColor: '#141414',
          borderTop: '1px solid #1E1E1E'
        }}
      >
        <div className="flex items-end gap-3">
          <div className="flex-1 relative">
            <textarea
              ref={inputRef}
              value={inputValue}
              onChange={(e) => setInputValue(e.target.value)}
              onKeyDown={handleKeyDown}
              placeholder="Message..."
              rows={1}
              className="w-full px-4 py-3 rounded-xl resize-none outline-none"
              style={{
                backgroundColor: '#1E1E1E',
                color: '#ffffff',
                border: 'none',
                maxHeight: '120px',
                minHeight: '48px'
              }}
              onInput={(e) => {
                const target = e.target as HTMLTextAreaElement;
                target.style.height = 'auto';
                target.style.height = Math.min(target.scrollHeight, 120) + 'px';
              }}
            />
          </div>

          {inputValue.trim() && (
            <button
              onClick={handleSend}
              className="w-12 h-12 rounded-full flex items-center justify-center flex-shrink-0 transition-all duration-200 hover:opacity-90"
              style={{
                backgroundColor: '#ffffff',
                color: '#0F0F0F'
              }}
            >
              <Send size={20} />
            </button>
          )}
        </div>

        <div
          className="mt-2 text-center"
          style={{
            fontSize: '11px',
            color: '#666666'
          }}
        >
          ⌘ + Return to send
        </div>
      </div>
    </div>
  );
}
