"use client";

import { useEffect, useState } from "react";

type FireworksProps = {
  duration?: number; // How long to show fireworks in ms
};

type Particle = {
  id: number;
  x: number;
  y: number;
  vx: number;
  vy: number;
  life: number;
  maxLife: number;
  color: string;
  size: number;
};

export function Fireworks({ duration = 5000 }: FireworksProps) {
  const [particles, setParticles] = useState<Particle[]>([]);
  const [isActive, setIsActive] = useState(true);

  useEffect(() => {
    const colors = [
      "#FFD700", // Gold
      "#FFA500", // Orange
      "#FF4500", // Red-Orange
      "#FF6B6B", // Light Red
      "#4ECDC4", // Turquoise
      "#45B7D1", // Sky Blue
      "#96CEB4", // Sage
      "#FFEAA7", // Light Yellow
      "#DFE6E9", // Light Gray
      "#74B9FF", // Light Blue
    ];

    let animationFrame: number;
    let lastTime = Date.now();
    let nextExplosion = Date.now() + 300; // First explosion after 300ms
    let particleIdCounter = 0;

    const createExplosion = (x: number, y: number) => {
      const newParticles: Particle[] = [];
      const particleCount = 40 + Math.random() * 40; // 40-80 particles
      const color = colors[Math.floor(Math.random() * colors.length)];

      for (let i = 0; i < particleCount; i++) {
        const angle = (Math.PI * 2 * i) / particleCount + (Math.random() - 0.5) * 0.5;
        const velocity = 2 + Math.random() * 4;
        const maxLife = 60 + Math.random() * 40; // 60-100 frames

        newParticles.push({
          id: particleIdCounter++,
          x,
          y,
          vx: Math.cos(angle) * velocity,
          vy: Math.sin(angle) * velocity - 1.5, // Add upward bias
          life: maxLife,
          maxLife,
          color: Math.random() > 0.3 ? color : colors[Math.floor(Math.random() * colors.length)],
          size: 2 + Math.random() * 3,
        });
      }

      setParticles((prev) => [...prev, ...newParticles]);
    };

    const animate = () => {
      const now = Date.now();
      const deltaTime = now - lastTime;
      lastTime = now;

      // Create new explosions randomly - start from bottom and explode upward
      if (now >= nextExplosion && isActive) {
        const x = 20 + Math.random() * 60; // 20-80% across
        const y = 70 + Math.random() * 20; // 70-90% down (near bottom)
        createExplosion(x, y);
        nextExplosion = now + 400 + Math.random() * 400; // Next explosion in 400-800ms
      }

      // Update particles
      setParticles((prevParticles) => {
        return prevParticles
          .map((particle) => ({
            ...particle,
            x: particle.x + particle.vx * (deltaTime / 16),
            y: particle.y + particle.vy * (deltaTime / 16),
            vy: particle.vy + 0.15, // Gravity
            vx: particle.vx * 0.99, // Air resistance
            life: particle.life - 1,
          }))
          .filter((particle) => particle.life > 0);
      });

      animationFrame = requestAnimationFrame(animate);
    };

    animationFrame = requestAnimationFrame(animate);

    // Stop creating new explosions after duration
    const stopTimer = setTimeout(() => {
      setIsActive(false);
    }, duration);

    // Cleanup
    return () => {
      cancelAnimationFrame(animationFrame);
      clearTimeout(stopTimer);
    };
  }, [duration, isActive]);

  return (
    <div className="absolute inset-0 pointer-events-none z-50 overflow-hidden" style={{ perspective: "1000px" }}>
      {particles.map((particle) => {
        const opacity = particle.life / particle.maxLife;
        return (
          <div
            key={particle.id}
            className="absolute rounded-full"
            style={{
              left: `${particle.x}%`,
              top: `${particle.y}%`,
              width: `${particle.size}px`,
              height: `${particle.size}px`,
              backgroundColor: particle.color,
              opacity: opacity,
              boxShadow: `0 0 ${particle.size * 2}px ${particle.color}`,
              transform: `translate(-50%, -50%) scale(${opacity})`,
              transition: "transform 0.1s ease-out",
            }}
          />
        );
      })}
    </div>
  );
}
