const express = require('express');
const router = express.Router();
const { sendWelcomeEmail, sendBookingConfirmationEmail } = require('../services/snsService');

/**
 * POST /api/notifications/welcome
 * Send welcome email to new user
 */
router.post('/welcome', async (req, res) => {
  try {
    const { email, userName } = req.body;

    if (!email || !userName) {
      return res.status(400).json({ 
        error: 'Missing required fields: email and userName' 
      });
    }

    await sendWelcomeEmail(email, userName);

    res.status(200).json({ 
      message: 'Welcome email sent successfully',
      email 
    });
  } catch (error) {
    console.error('Error sending welcome email:', error);
    res.status(500).json({ 
      error: 'Failed to send welcome email',
      message: error.message 
    });
  }
});

/**
 * POST /api/notifications/booking-confirmation
 * Send booking confirmation email
 */
router.post('/booking-confirmation', async (req, res) => {
  try {
    const { email, userName, eventDetails, bookingDetails } = req.body;

    if (!email || !userName || !eventDetails || !bookingDetails) {
      return res.status(400).json({ 
        error: 'Missing required fields: email, userName, eventDetails, bookingDetails' 
      });
    }

    await sendBookingConfirmationEmail(email, userName, eventDetails, bookingDetails);

    res.status(200).json({ 
      message: 'Booking confirmation email sent successfully',
      email,
      bookingId: bookingDetails.bookingId
    });
  } catch (error) {
    console.error('Error sending booking confirmation email:', error);
    res.status(500).json({ 
      error: 'Failed to send booking confirmation email',
      message: error.message 
    });
  }
});

module.exports = router;
