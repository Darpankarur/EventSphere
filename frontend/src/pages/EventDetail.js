import React, { useState, useEffect } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import axios from 'axios';
import API_CONFIG from '../config/api';
import './EventDetail.css';

function EventDetail({ user }) {
  const { id } = useParams();
  const navigate = useNavigate();
  const [event, setEvent] = useState(null);
  const [loading, setLoading] = useState(true);
  const [tickets, setTickets] = useState(1);
  const [booking, setBooking] = useState(false);
  const [message, setMessage] = useState('');

  useEffect(() => {
    fetchEvent();
  }, [id]);

  const fetchEvent = async () => {
    try {
      const response = await axios.get(`${API_CONFIG.event}/events/${id}`);
      setEvent(response.data);
    } catch (err) {
      console.error('Error fetching event:', err);
    } finally {
      setLoading(false);
    }
  };

  const handleBooking = async () => {
    if (!user) {
      navigate('/login');
      return;
    }

    setBooking(true);
    setMessage('');

    try {
      const token = localStorage.getItem('token');
      const response = await axios.post(
        `${API_CONFIG.booking}/bookings`,
        {
          eventId: event._id,
          numberOfTickets: tickets,
          paymentMethod: 'credit_card'
        },
        {
          headers: { Authorization: `Bearer ${token}` }
        }
      );

      setMessage(`Booking confirmed! Reference: ${response.data.booking.bookingReference}`);
      setTimeout(() => navigate('/my-bookings'), 2000);
    } catch (err) {
      setMessage(err.response?.data?.error || 'Booking failed');
    } finally {
      setBooking(false);
    }
  };

  if (loading) return <div className="loading">Loading event...</div>;
  if (!event) return <div>Event not found</div>;

  return (
    <div className="event-detail">
      <img src={event.imageUrl} alt={event.title} className="event-detail-image" />
      <div className="event-detail-content">
        <h1>{event.title}</h1>
        <span className="event-category">{event.category}</span>
        <p className="event-description">{event.description}</p>
        
        <div className="event-details">
          <div className="detail-item">
            <strong>Date:</strong> {new Date(event.date).toLocaleDateString()}
          </div>
          <div className="detail-item">
            <strong>Time:</strong> {event.time}
          </div>
          <div className="detail-item">
            <strong>Venue:</strong> {event.venue}
          </div>
          <div className="detail-item">
            <strong>Organizer:</strong> {event.organizer}
          </div>
          <div className="detail-item">
            <strong>Price:</strong> ${event.price} per ticket
          </div>
          <div className="detail-item">
            <strong>Available Seats:</strong> {event.availableSeats} / {event.capacity}
          </div>
        </div>

        {event.availableSeats > 0 ? (
          <div className="booking-section">
            <label>Number of tickets:</label>
            <input
              type="number"
              min="1"
              max={Math.min(event.availableSeats, 10)}
              value={tickets}
              onChange={(e) => setTickets(parseInt(e.target.value))}
            />
            <p className="total">Total: ${event.price * tickets}</p>
            <button 
              onClick={handleBooking} 
              className="btn btn-primary"
              disabled={booking}
            >
              {booking ? 'Booking...' : 'Book Now'}
            </button>
          </div>
        ) : (
          <p className="sold-out">Sorry, this event is sold out!</p>
        )}

        {message && (
          <div className={message.includes('confirmed') ? 'success' : 'error'}>
            {message}
          </div>
        )}
      </div>
    </div>
  );
}

export default EventDetail;
