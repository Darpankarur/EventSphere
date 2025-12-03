const express = require('express');
const axios = require('axios');
const Booking = require('../models/Booking');
const { verifyToken } = require('../middleware/auth');

const router = express.Router();

const EVENT_SERVICE_URL = process.env.EVENT_SERVICE_URL || 'http://localhost:4002';
const NOTIFICATION_SERVICE_URL = process.env.NOTIFICATION_SERVICE_URL || 'http://localhost:4004';

// POST /api/bookings - Create a new booking
router.post('/', verifyToken, async (req, res) => {
  try {
    const { eventId, numberOfTickets, paymentMethod } = req.body;

    // Validate input
    if (!eventId || !numberOfTickets) {
      return res.status(400).json({ error: 'Event ID and number of tickets are required' });
    }

    // Fetch event details from event-service
    let eventResponse;
    try {
      eventResponse = await axios.get(`${EVENT_SERVICE_URL}/api/events/${eventId}`);
    } catch (err) {
      return res.status(404).json({ error: 'Event not found' });
    }

    const event = eventResponse.data;

    // Check if event has enough available seats
    if (event.availableSeats < numberOfTickets) {
      return res.status(400).json({ 
        error: 'Not enough seats available',
        availableSeats: event.availableSeats,
        requested: numberOfTickets
      });
    }

    // Check if event is in the future
    if (new Date(event.date) < new Date()) {
      return res.status(400).json({ error: 'Cannot book tickets for past events' });
    }

    // Check if event is cancelled
    if (event.status === 'cancelled') {
      return res.status(400).json({ error: 'Event has been cancelled' });
    }

    // Create booking
    const booking = new Booking({
      userId: req.user._id,
      userName: req.user.name,
      userEmail: req.user.email,
      eventId: event._id,
      eventTitle: event.title,
      eventDate: event.date,
      eventVenue: event.venue,
      numberOfTickets,
      pricePerTicket: event.price,
      paymentMethod: paymentMethod || 'credit_card'
    });

    // Simulate payment processing (in real app, integrate Stripe/Razorpay)
    const paymentSuccess = Math.random() > 0.1; // 90% success rate for demo

    if (paymentSuccess) {
      booking.paymentStatus = 'completed';
      booking.bookingStatus = 'confirmed';
      booking.transactionId = `TXN${Date.now()}${Math.floor(Math.random() * 10000)}`;

      // Update available seats in event-service
      try {
        await axios.patch(`${EVENT_SERVICE_URL}/api/events/${eventId}/seats`, {
          seatsToBook: numberOfTickets
        });
      } catch (err) {
        return res.status(500).json({ 
          error: 'Failed to update event seats',
          details: err.response?.data || err.message
        });
      }

      await booking.save();

      // Send booking confirmation email (non-blocking)
      axios.post(`${NOTIFICATION_SERVICE_URL}/api/notifications/booking-confirmation`, {
        email: req.user.email,
        userName: req.user.name,
        eventDetails: {
          title: event.title,
          date: event.date,
          time: event.time,
          venue: event.venue,
          category: event.category
        },
        bookingDetails: {
          bookingId: booking.bookingReference,
          quantity: booking.numberOfTickets,
          totalAmount: booking.totalAmount,
          bookingDate: booking.createdAt
        }
      }).catch(err => {
        console.error('Failed to send booking confirmation email:', err.message);
        // Don't fail booking if notification fails
      });

      res.status(201).json({
        message: 'Booking confirmed successfully',
        booking: {
          bookingReference: booking.bookingReference,
          eventTitle: booking.eventTitle,
          eventDate: booking.eventDate,
          eventVenue: booking.eventVenue,
          numberOfTickets: booking.numberOfTickets,
          totalAmount: booking.totalAmount,
          paymentStatus: booking.paymentStatus,
          transactionId: booking.transactionId,
          bookingStatus: booking.bookingStatus
        }
      });
    } else {
      booking.paymentStatus = 'failed';
      booking.bookingStatus = 'pending';
      await booking.save();

      res.status(400).json({
        error: 'Payment failed. Please try again.',
        bookingReference: booking.bookingReference
      });
    }
  } catch (err) {
    console.error('Booking creation error:', err);
    res.status(500).json({ error: 'Failed to create booking', details: err.message });
  }
});

// GET /api/bookings - Get all bookings for logged-in user
router.get('/', verifyToken, async (req, res) => {
  try {
    const bookings = await Booking.find({ userId: req.user._id })
      .sort({ createdAt: -1 });

    res.json({
      count: bookings.length,
      bookings
    });
  } catch (err) {
    console.error('Get bookings error:', err);
    res.status(500).json({ error: 'Failed to fetch bookings', details: err.message });
  }
});

// GET /api/bookings/:id - Get single booking
router.get('/:id', verifyToken, async (req, res) => {
  try {
    const booking = await Booking.findById(req.params.id);

    if (!booking) {
      return res.status(404).json({ error: 'Booking not found' });
    }

    // Check if booking belongs to user
    if (booking.userId !== req.user._id && req.user.role !== 'admin') {
      return res.status(403).json({ error: 'Access denied' });
    }

    res.json(booking);
  } catch (err) {
    console.error('Get booking error:', err);
    res.status(500).json({ error: 'Failed to fetch booking', details: err.message });
  }
});

// GET /api/bookings/reference/:reference - Get booking by reference number
router.get('/reference/:reference', verifyToken, async (req, res) => {
  try {
    const booking = await Booking.findOne({ bookingReference: req.params.reference });

    if (!booking) {
      return res.status(404).json({ error: 'Booking not found' });
    }

    // Check if booking belongs to user
    if (booking.userId !== req.user._id && req.user.role !== 'admin') {
      return res.status(403).json({ error: 'Access denied' });
    }

    res.json(booking);
  } catch (err) {
    console.error('Get booking by reference error:', err);
    res.status(500).json({ error: 'Failed to fetch booking', details: err.message });
  }
});

// PATCH /api/bookings/:id/cancel - Cancel a booking
router.patch('/:id/cancel', verifyToken, async (req, res) => {
  try {
    const booking = await Booking.findById(req.params.id);

    if (!booking) {
      return res.status(404).json({ error: 'Booking not found' });
    }

    // Check if booking belongs to user
    if (booking.userId !== req.user._id && req.user.role !== 'admin') {
      return res.status(403).json({ error: 'Access denied' });
    }

    // Check if booking is already cancelled
    if (booking.bookingStatus === 'cancelled') {
      return res.status(400).json({ error: 'Booking is already cancelled' });
    }

    // Check if event date has passed
    if (new Date(booking.eventDate) < new Date()) {
      return res.status(400).json({ error: 'Cannot cancel booking for past events' });
    }

    // Update booking status
    booking.bookingStatus = 'cancelled';
    booking.paymentStatus = 'refunded';
    await booking.save();

    // Return seats to event (restore availability)
    try {
      await axios.patch(`${EVENT_SERVICE_URL}/api/events/${booking.eventId}/seats`, {
        seatsToBook: -booking.numberOfTickets // negative to add seats back
      });
    } catch (err) {
      console.error('Failed to restore event seats:', err.message);
      // Continue anyway - booking is cancelled
    }

    res.json({
      message: 'Booking cancelled successfully',
      booking: {
        bookingReference: booking.bookingReference,
        bookingStatus: booking.bookingStatus,
        paymentStatus: booking.paymentStatus,
        refundAmount: booking.totalAmount
      }
    });
  } catch (err) {
    console.error('Cancel booking error:', err);
    res.status(500).json({ error: 'Failed to cancel booking', details: err.message });
  }
});

// GET /api/bookings/event/:eventId - Get all bookings for an event (admin only)
router.get('/event/:eventId', verifyToken, async (req, res) => {
  try {
    if (req.user.role !== 'admin') {
      return res.status(403).json({ error: 'Access denied. Admin only.' });
    }

    const bookings = await Booking.find({ eventId: req.params.eventId })
      .sort({ createdAt: -1 });

    const stats = {
      totalBookings: bookings.length,
      confirmedBookings: bookings.filter(b => b.bookingStatus === 'confirmed').length,
      cancelledBookings: bookings.filter(b => b.bookingStatus === 'cancelled').length,
      totalRevenue: bookings
        .filter(b => b.paymentStatus === 'completed')
        .reduce((sum, b) => sum + b.totalAmount, 0),
      totalTicketsSold: bookings
        .filter(b => b.bookingStatus === 'confirmed')
        .reduce((sum, b) => sum + b.numberOfTickets, 0)
    };

    res.json({
      stats,
      bookings
    });
  } catch (err) {
    console.error('Get event bookings error:', err);
    res.status(500).json({ error: 'Failed to fetch bookings', details: err.message });
  }
});

module.exports = router;