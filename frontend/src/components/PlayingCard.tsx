import Image from "next/image";
import { useState, useEffect, useRef } from "react";

type PlayingCardProps = {
  cardValue: number;
  isHidden?: boolean;
  className?: string;
  shouldFlip?: boolean; // Triggers the flip animation
  shouldFadeIn?: boolean; // Triggers the fade-in animation (only on prop change)
};

// Contract card system: cardId 1-52
// Rank calculation: ((cardId - 1) % 13) + 1 gives ranks 1-13 (A, 2-10, J, Q, K)
// Suit calculation: Math.floor((cardId - 1) / 13) gives 0-3 for four suits
// Match the slice_cards.py CARD_MAP layout and standard playing card order
const CARD_NAMES = ["", "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]; // Index 0 unused, 1-13 = A-K
const SUITS = ["clubs", "diamonds", "hearts", "spades"]; // Standard order for card decks
const SUIT_SYMBOLS = ["♣", "♦", "♥", "♠"];

export function PlayingCard({ cardValue, isHidden = false, className = "", shouldFlip = false, shouldFadeIn = false }: PlayingCardProps) {
  // Track previous shouldFlip value to detect changes
  const prevShouldFlipRef = useRef<boolean | null>(null);
  // Track previous shouldFadeIn value to detect changes
  const prevShouldFadeInRef = useRef<boolean | null>(null);
  // Track if this is the very first render
  const isFirstRenderRef = useRef(true);
  
  // Track if we should be showing front
  // Initial state: if isHidden=true, show back (showFront=false); if isHidden=false, show front (showFront=true)
  const [showFront, setShowFront] = useState(!isHidden);
  
  // Track if animation should be enabled
  const [enableAnimation, setEnableAnimation] = useState(false);
  
  // Track if fade-in should be applied
  const [applyFadeIn, setApplyFadeIn] = useState(false);


  // Detect when shouldFlip changes from false to true - this triggers the flip animation
  useEffect(() => {

    // First render: record the initial value
    if (prevShouldFlipRef.current === null) {
      prevShouldFlipRef.current = shouldFlip;
      
      // SPECIAL CASE: If isHidden=true and shouldFlip=true on first render,
      // this means the component mounted AFTER the parent already set shouldFlip=true
      // We need to trigger the animation anyway!
      if (isHidden && shouldFlip && isFirstRenderRef.current) {
        // Wait one frame for the card to render, then enable animation
        requestAnimationFrame(() => {
          setEnableAnimation(true);
        });
      }
      
      isFirstRenderRef.current = false;
      return;
    }
    
    // Detect transition from false to true - this is when we flip with animation
    if (prevShouldFlipRef.current === false && shouldFlip === true) {
      // Step 1: Enable animation (this sets the CSS transition property)
      setEnableAnimation(true);
    }
    
    // Update ref for future comparisons
    prevShouldFlipRef.current = shouldFlip;
  }, [shouldFlip, cardValue, showFront, isHidden]);

  // Separate effect: once animation is enabled, schedule the flip
  // This ensures the browser has painted the transition CSS before we change the transform
  useEffect(() => {
    if (enableAnimation && shouldFlip && !showFront) {
      // Double requestAnimationFrame ensures:
      // 1st RAF: Browser commits the transition CSS to the render tree
      // 2nd RAF: Browser paints, then we can safely change showFront
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          setShowFront(true);
        });
      });
    }
  }, [enableAnimation, shouldFlip, showFront]);

  // Detect when shouldFadeIn changes from false to true - this triggers the fade-in animation
  useEffect(() => {

    // First render: just record the initial value, don't animate
    if (prevShouldFadeInRef.current === null) {
      prevShouldFadeInRef.current = shouldFadeIn;
      return;
    }
    
    // Detect transition from false to true - this is when we fade in
    if (prevShouldFadeInRef.current === false && shouldFadeIn === true) {
      setApplyFadeIn(true);
      // Remove the animation class after animation completes (0.5s duration)
      setTimeout(() => {
        setApplyFadeIn(false);
      }, 500);
    }
    
    // Update ref for future comparisons
    prevShouldFadeInRef.current = shouldFadeIn;
  }, [shouldFadeIn, cardValue]);

  // Contract uses 1-52 card IDs
  // Rank: ((cardValue - 1) % 13) + 1 = 1-13 (Ace, 2-10, Jack, Queen, King)
  // Suit: Math.floor((cardValue - 1) / 13) = 0-3 (clubs, diamonds, hearts, spades)
  const rankValue = ((cardValue - 1) % 13) + 1;  // 1-13
  const suitIndex = Math.floor((cardValue - 1) / 13);  // 0-3 for suits
  
  const rank = CARD_NAMES[rankValue];  // Use 1-indexed array
  const suit = SUITS[suitIndex];
  const suitSymbol = SUIT_SYMBOLS[suitIndex];

  const imagePath = `/cards/${rank}_${suit}.png`;
  
  // Build className with fade-in if triggered
  const finalClassName = `${className} ${applyFadeIn ? 'animate-fade-in-card' : ''} playing-card-shadow`.trim();

  // If this card can flip (hole card), always use 3D structure
  // This prevents flicker when transitioning from hidden to revealed
  if (isHidden || shouldFlip) {
    return (
      <div 
        className={`relative w-24 h-32 ${finalClassName}`} 
        style={{ perspective: "1000px" }}
        title={isHidden && !showFront ? "Hidden card" : `${rank}${suitSymbol}`}
      >
        <div 
          className="card-flip-inner"
          style={{
            transformStyle: "preserve-3d",
            position: "relative",
            width: "100%",
            height: "100%",
            transform: showFront ? "rotateY(0deg)" : "rotateY(180deg)",
            transition: enableAnimation ? "transform 0.7s ease-in-out" : "none",
          }}
        >
          {/* Back of card */}
          <div 
            className="card-flip-back"
            style={{
              position: "absolute",
              width: "100%",
              height: "100%",
              backfaceVisibility: "hidden",
              WebkitBackfaceVisibility: "hidden",
              transform: "rotateY(180deg)"
            }}
          >
            <Image
              src="/cards/back.png"
              alt="Hidden card"
              fill
              className="object-contain"
            />
          </div>
          
          {/* Front of card */}
          <div 
            className="card-flip-front"
            style={{
              position: "absolute",
              width: "100%",
              height: "100%",
              backfaceVisibility: "hidden",
              WebkitBackfaceVisibility: "hidden",
            }}
          >
            <Image
              src={imagePath}
              alt={`${rank} of ${suit}`}
              fill
              className="object-contain"
            />
          </div>
        </div>
      </div>
    );
  }

  // Simple case: just show the front of the card (for regular player/dealer cards)
  return (
    <div className={`relative w-24 h-32 ${finalClassName}`} title={`${rank}${suitSymbol}`}>
      <Image
        src={imagePath}
        alt={`${rank} of ${suit}`}
        fill
        className="object-contain"
      />
    </div>
  );
}
