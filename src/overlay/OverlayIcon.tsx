import React from "react";

interface OverlayIconProps {
  className?: string;
}

// Circled sound-bars mark (OpenWhispr-style identity). Drawn in currentColor so
// the overlay states only restyle it through CSS.
const OverlayIcon: React.FC<OverlayIconProps> = ({ className }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" aria-hidden="true">
    <circle cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="2" />
    <rect x="7.75" y="9.5" width="2" height="5" rx="1" fill="currentColor" />
    <rect x="11" y="7" width="2" height="10" rx="1" fill="currentColor" />
    <rect x="14.25" y="9.5" width="2" height="5" rx="1" fill="currentColor" />
  </svg>
);

export default OverlayIcon;
