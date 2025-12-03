import React, { useState, useEffect } from 'react';
import axios from 'axios';
import API_CONFIG from '../config/api';
import './MyBookings.css';

function MyBookings() {
  const [bookings, setBookings] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetchBookings();
  }, []);

  const fetchBookings = async () => {
    try {
      const token = localStorage.getItem('token');
      const response = await axios.get(`${API_CONFIG.booking}/bookings`, {
        headers: { Authorization: `Bearer ${token}` }
      });
      setBookings(response.data.bookings);
    } catch (err) {
      console.error('Error fetching bookings:', err);
    } finally {
      setLoading(false);
    }
  };

  const handleCancel = async (bookingId) => {
    if (!window.confirm('Are you sure you want to cancel this booking?')) return;

    try {
      const token = localStorage.getItem('token');
      await axios.patch(
        `${API_CONFIG.booking}/bookings/${bookingId}/cancel`,
        {},
        { headers: { Authorization: `Bearer ${token}` } }
      );
      fetchBookings();
      alert('Booking cancelled successfully!');
    } catch (err) {
      alert(err.response?.data?.error || 'Failed to cancel booking');
    }
  };

  if (loading) return <div className="loading">Loading bookings...</div>;

  return (
    <div className="my-bookings">
      <h1>My Bookings</h1>
      {bookings.length === 0 ? (
        <p>No bookings yet</p>
      ) : (
        <div className="bookings-list">
          {bookings.map(booking => (
            <div key={booking._id} className="booking-card">
              <div className="booking-header">
                <h3>{booking.eventTitle}</h3>
                <span className={`status ${booking.bookingStatus}`}>
                  {booking.bookingStatus}
                </span>
              </div>
              <p><strong>Reference:</strong> {booking.bookingReference}</p>
              <p><strong>Date:</strong> {new Date(booking.eventDate).toLocaleDateString()}</p>
              <p><strong>Venue:</strong> {booking.eventVenue}</p>
              <p><strong>Tickets:</strong> {booking.numberOfTickets}</p>
              <p><strong>Total Amount:</strong> ${booking.totalAmount}</p>
              <p><strong>Payment:</strong> {booking.paymentStatus}</p>
              {booking.bookingStatus === 'confirmed' && (
                <button 
                  onClick={() => handleCancel(booking._id)}
                  className="btn btn-danger"
                >
                  Cancel Booking
                </button>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

export default MyBookings;
